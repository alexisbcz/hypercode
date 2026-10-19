import Foundation
import Observation

@Observable
final class Session: Identifiable {
    let id: String
    let project: Project
    var title: String
    var date: Date
    var entries: [Entry] = []
    var isRunning = false
    /// Messages sent while Claude is working; each goes out when the current turn ends.
    var queue: [QueuedMessage] = []
    /// Set by Stop so an interrupted turn doesn't immediately roll into the queue.
    var isQueuePaused = false

    private var hasHistory: Bool
    private var isLoaded: Bool
    private var process: ClaudeProcess?
    private var messageID = ""
    private var blockEntries: [Int: Int] = [:]
    private var pendingThinking: [Int: String] = [:]
    private var toolEntries: [String: Int] = [:]

    init(project: Project, title: String) {
        id = UUID().uuidString.lowercased()
        self.project = project
        self.title = title
        date = .now
        hasHistory = false
        isLoaded = true
    }

    init(project: Project, summary: SessionSummary) {
        id = summary.id
        self.project = project
        title = summary.title
        date = summary.date
        hasHistory = true
        isLoaded = false
    }

    func loadIfNeeded() async {
        guard !isLoaded else { return }
        isLoaded = true
        let file = Transcript.file(for: project.url, session: id)
        entries = await Task.detached { Transcript.entries(at: file) }.value
        reindexTools()
    }

    func send(_ text: String, attachments: [Attachment] = [], config: RunConfig) {
        if isRunning {
            queue.append(QueuedMessage(text: text, attachments: attachments, config: config))
            return
        }
        start(text, attachments: attachments, config: config)
    }

    /// Sends a queued message right away, interrupting the current turn if there is one.
    func sendNow(_ message: QueuedMessage) {
        queue.removeAll { $0.id == message.id }
        if isRunning { stop() }
        isQueuePaused = false
        start(message.text, attachments: message.attachments, config: message.config)
    }

    func resumeQueue() {
        isQueuePaused = false
        flushQueue()
    }

    private func flushQueue() {
        guard !isRunning, !isQueuePaused, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        start(next.text, attachments: next.attachments, config: next.config)
    }

    private func start(_ text: String, attachments: [Attachment], config: RunConfig) {
        let files = attachments.compactMap { if case .file(let url) = $0.kind { url } else { nil } }
        entries.append(Entry(
            id: UUID().uuidString, kind: .user, text: text,
            images: attachments.compactMap(\.imageData), files: files.map(\.lastPathComponent)
        ))
        let content = Self.content(text: text, attachments: attachments, files: files, root: project.url)
        date = .now
        isRunning = true

        if let process, process.isRunning, process.config == config {
            process.send(content)
            return
        }
        process?.terminate()
        guard FileManager.default.fileExists(atPath: project.url.path) else {
            append(.error, "The folder \(project.url.path) no longer exists.")
            isRunning = false
            return
        }
        let process = ClaudeProcess(sessionID: id, resume: hasHistory, cwd: project.url, config: config)
        process.onEvent = { [weak self] in self?.handle($0) }
        process.onExit = { [weak self, weak process] status, stderr in
            guard let self, self.process === process else { return }
            self.process = nil
            if self.isRunning, status != 0, status != SIGINT {
                self.append(.error, stderr.isEmpty ? "Claude exited with status \(status)." : stderr)
            }
            self.isRunning = false
            self.flushQueue()
        }
        do {
            try process.start()
            self.process = process
            hasHistory = true
            process.send(content)
        } catch {
            append(.error, "Couldn't launch claude at \(Shell.claude.path): \(error.localizedDescription)")
            isRunning = false
        }
    }

    func stop() {
        // Detach first: the interrupted process may linger, and the next send needs a fresh one.
        process?.interrupt()
        process = nil
        isRunning = false
        isQueuePaused = !queue.isEmpty
    }

    /// Images become base64 image blocks; other files are referenced by path for Claude to read.
    private static func content(text: String, attachments: [Attachment], files: [URL], root: URL) -> Any {
        var prompt = text
        if !files.isEmpty {
            let paths = files.map { url in
                url.path.hasPrefix(root.path + "/") ? String(url.path.dropFirst(root.path.count + 1)) : url.path
            }
            prompt += (prompt.isEmpty ? "" : "\n\n") + "Attached files:\n" + paths.map { "- \($0)" }.joined(separator: "\n")
        }
        let images: [[String: Any]] = attachments.compactMap {
            guard case .image(let data, let mediaType) = $0.kind else { return nil }
            return ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data.base64EncodedString()]]
        }
        guard !images.isEmpty else { return prompt }
        return images + (prompt.isEmpty ? [] : [["type": "text", "text": prompt]])
    }

    // MARK: - Stream events

    private func handle(_ event: JSON) {
        switch event["type"]?.string {
        case "stream_event":
            if let e = event["event"] { handleStream(e) }
        case "assistant":
            for block in event["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_use" {
                guard let id = block["id"]?.string else { continue }
                upsertTool(id: id, name: block["name"]?.string ?? "Tool").map { entries[$0].tool?.input = block["input"] }
            }
        case "user":
            for block in event["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_result" {
                guard let id = block["tool_use_id"]?.string, let index = toolEntries[id] else { continue }
                entries[index].tool?.result = block["content"]?.flattenedText ?? ""
                entries[index].tool?.isError = block["is_error"]?.bool ?? false
            }
        case "result":
            isRunning = false
            if event["is_error"]?.bool == true {
                append(.error, event["result"]?.string ?? "Something went wrong.")
            }
            refreshTitle()
            flushQueue()
        default:
            break
        }
    }

    private func handleStream(_ e: JSON) {
        switch e["type"]?.string {
        case "message_start":
            messageID = e["message"]?["id"]?.string ?? UUID().uuidString
            blockEntries = [:]
            pendingThinking = [:]
        case "content_block_start":
            guard case .number(let i)? = e["index"], let block = e["content_block"] else { return }
            let id = "\(messageID)-\(Int(i))"
            switch block["type"]?.string {
            case "text":
                blockEntries[Int(i)] = entries.count
                entries.append(Entry(id: id, kind: .assistant))
            case "thinking":
                // Often stays empty (hidden thinking), so the row waits for its first text.
                pendingThinking[Int(i)] = id
            case "tool_use":
                if let toolID = block["id"]?.string { _ = upsertTool(id: toolID, name: block["name"]?.string ?? "Tool") }
            default: break
            }
        case "content_block_delta":
            guard case .number(let i)? = e["index"], let delta = e["delta"],
                  let text = delta["text"]?.string ?? delta["thinking"]?.string, !text.isEmpty
            else { return }
            if blockEntries[Int(i)] == nil, let id = pendingThinking.removeValue(forKey: Int(i)) {
                blockEntries[Int(i)] = entries.count
                entries.append(Entry(id: id, kind: .thinking))
            }
            guard let index = blockEntries[Int(i)] else { return }
            entries[index].text += text
        default:
            break
        }
    }

    private func upsertTool(id: String, name: String) -> Int? {
        if let index = toolEntries[id] { return index }
        toolEntries[id] = entries.count
        entries.append(Entry(id: id, kind: .tool, tool: ToolCall(name: name)))
        return entries.count - 1
    }

    private func append(_ kind: Entry.Kind, _ text: String) {
        entries.append(Entry(id: UUID().uuidString, kind: kind, text: text))
    }

    private func reindexTools() {
        toolEntries = [:]
        for (i, entry) in entries.enumerated() where entry.kind == .tool { toolEntries[entry.id] = i }
    }

    private func refreshTitle() {
        let file = Transcript.file(for: project.url, session: id)
        Task {
            if let title = await Task.detached(operation: { Transcript.title(at: file) }).value { self.title = title }
        }
    }
}

struct QueuedMessage: Identifiable {
    let id = UUID()
    var text: String
    var attachments: [Attachment]
    let config: RunConfig
}
