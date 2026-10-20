import Foundation

/// Reads the sessions Claude Code stores under ~/.claude/projects.
nonisolated enum Transcript {
    static func directory(for project: URL) -> URL {
        let encoded = String(project.path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects/\(encoded)", directoryHint: .isDirectory)
    }

    static func file(for project: URL, session id: String) -> URL {
        directory(for: project).appending(path: "\(id).jsonl")
    }

    static func summaries(for project: URL, limit: Int = 50) -> [SessionSummary] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: directory(for: project), includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let dated = files
            .filter { $0.pathExtension == "jsonl" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
        return dated.compactMap { url, date in
            guard let title = title(at: url) else { return nil }
            return SessionSummary(id: url.deletingPathExtension().lastPathComponent, title: title, date: date)
        }
    }

    /// Custom title, then AI title, then the first prompt. Nil when the session never had a prompt.
    static func title(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var custom: String?, ai: String?, prompt: String?
        for line in data.split(separator: 0x0A) {
            let head = String(decoding: line.prefix(48), as: UTF8.self)
            if head.contains("\"custom-title\"") {
                custom = JSON.parse(Data(line))?["customTitle"]?.string ?? custom
            } else if head.contains("\"ai-title\"") {
                ai = JSON.parse(Data(line))?["aiTitle"]?.string ?? ai
            } else if prompt == nil, head.contains("\"last-prompt\"") {
                prompt = JSON.parse(Data(line))?["lastPrompt"]?.string
            }
        }
        return (custom ?? ai ?? prompt).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The visible entries, and how full the context was after the last reply (nil after a compaction).
    static func entries(at url: URL) -> (entries: [Entry], contextTokens: Int?) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return ([], nil) }
        var entries: [Entry] = []
        var contextTokens: Int?
        var toolIndex: [String: Int] = [:]

        for event in events(in: data) {
            guard event["isSidechain"]?.bool != true, event["isMeta"]?.bool != true,
                  event["isCompactSummary"]?.bool != true,
                  let type = event["type"]?.string
            else { continue }
            let uuid = event["uuid"]?.string ?? UUID().uuidString

            if type == "system" {
                switch event["subtype"]?.string {
                case "local_command":
                    if let entry = commandEntry(event["content"]?.string ?? "", id: uuid) { entries.append(entry) }
                case "compact_boundary":
                    entries.append(Entry(id: uuid, kind: .notice, text: "Conversation compacted"))
                    contextTokens = nil
                default: break
                }
                continue
            }
            guard type == "user" || type == "assistant", let content = event["message"]?["content"] else { continue }

            if let text = content.string {
                if let entry = commandEntry(text, id: uuid) {
                    entries.append(entry)
                } else if let prompt = visiblePrompt(text) {
                    entries.append(Entry(id: uuid, kind: .user, text: prompt))
                }
                continue
            }
            // Replies from built-in commands (/context, /usage…) and API errors aren't Claude speaking.
            let isSynthetic = type == "assistant" && event["message"]?["model"]?.string == "<synthetic>"
            if type == "assistant", !isSynthetic, let usage = event["message"]?["usage"] {
                contextTokens = Self.contextTokens(usage)
            }
            var images: [Data] = []
            defer {
                if !images.isEmpty {
                    if let last = entries.indices.last, entries[last].kind == .user, entries[last].id.hasPrefix(uuid) {
                        entries[last].images = images
                    } else {
                        entries.append(Entry(id: "\(uuid)-images", kind: .user, images: images))
                    }
                }
            }
            for (i, block) in (content.array ?? []).enumerated() {
                let id = "\(uuid)-\(i)"
                switch block["type"]?.string {
                case "text":
                    let text = block["text"]?.string ?? ""
                    if type == "assistant" {
                        entries.append(Entry(id: id, kind: isSynthetic ? .notice : .assistant, text: text))
                    } else if let entry = commandEntry(text, id: id) {
                        entries.append(entry)
                    } else if let prompt = visiblePrompt(text) {
                        entries.append(Entry(id: id, kind: .user, text: prompt))
                    }
                case "image" where type == "user":
                    if let base64 = block["source"]?["data"]?.string, let data = Data(base64Encoded: base64) {
                        images.append(data)
                    }
                case "thinking":
                    let text = block["thinking"]?.string ?? ""
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        entries.append(Entry(id: id, kind: .thinking, text: text))
                    }
                case "tool_use":
                    let toolID = block["id"]?.string ?? id
                    toolIndex[toolID] = entries.count
                    entries.append(Entry(id: toolID, kind: .tool, tool: ToolCall(name: block["name"]?.string ?? "Tool", input: block["input"])))
                case "tool_result":
                    if let toolID = block["tool_use_id"]?.string, let index = toolIndex[toolID] {
                        entries[index].tool?.result = block["content"]?.flattenedText ?? ""
                        entries[index].tool?.isError = block["is_error"]?.bool ?? false
                    }
                default: break
                }
            }
        }
        return (entries, contextTokens)
    }

    /// Everything a request put in the context window: fresh, cached and generated tokens.
    /// The conversation's events, in order. Bookkeeping records (API request blobs, file history, titles)
    /// all start with `{"type":` and are most of a long session's bytes, so they're skipped unparsed;
    /// the rest are parsed on every core.
    private static func events(in data: Data) -> [JSON] {
        let prefix = Data(#"{"type":""#.utf8)
        let lines = data.split(separator: 0x0A).filter { !$0.starts(with: prefix) }
        let chunk = max(64, lines.count / (ProcessInfo.processInfo.activeProcessorCount * 4))
        let chunks = stride(from: 0, to: lines.count, by: chunk).map { $0..<min($0 + chunk, lines.count) }
        let results = UnsafeResults(count: chunks.count)
        DispatchQueue.concurrentPerform(iterations: chunks.count) { i in
            results.set(i, chunks[i].compactMap { JSON.parse(Data(lines[$0])) })
        }
        return results.values.flatMap { $0 }
    }

    /// Per-chunk slots written by `concurrentPerform`; each index is written by exactly one iteration.
    private final class UnsafeResults: @unchecked Sendable {
        private let slots: UnsafeMutableBufferPointer<[JSON]>
        init(count: Int) {
            slots = .allocate(capacity: count)
            slots.initialize(repeating: [])
        }
        deinit {
            slots.deinitialize()
            slots.deallocate()
        }
        func set(_ i: Int, _ value: [JSON]) { slots[i] = value }
        var values: [[JSON]] { Array(slots) }
    }

    static func contextTokens(_ usage: JSON) -> Int {
        ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"].reduce(0) { sum, key in
            if case .number(let n)? = usage[key] { return sum + Int(n) }
            return sum
        }
    }

    static func appendTitle(_ title: String, to url: URL, session id: String) {
        guard let handle = try? FileHandle(forWritingTo: url),
              var data = try? JSONEncoder().encode(["type": "custom-title", "customTitle": title, "sessionId": id])
        else { return }
        defer { try? handle.close() }
        data.append(0x0A)
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// A slash command the user ran, or what it printed, from the tags Claude Code records them with.
    static func commandEntry(_ text: String, id: String) -> Entry? {
        if let name = tag("command-name", in: text) {
            let args = tag("command-args", in: text) ?? ""
            let command = (name.hasPrefix("/") ? name : "/" + name) + (args.isEmpty ? "" : " " + args)
            return Entry(id: id, kind: .command, text: command)
        }
        if let output = tag("local-command-stdout", in: text) ?? tag("local-command-stderr", in: text) {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : Entry(id: id, kind: .notice, text: trimmed)
        }
        return nil
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hides harness-injected messages (command wrappers, reminders, interrupts).
    private static func visiblePrompt(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("<") || t.hasPrefix("[Request interrupted") { return nil }
        return t
    }
}
