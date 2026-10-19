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

    static func entries(at url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        var entries: [Entry] = []
        var toolIndex: [String: Int] = [:]

        for line in data.split(separator: 0x0A) {
            guard let event = JSON.parse(Data(line)),
                  event["isSidechain"]?.bool != true, event["isMeta"]?.bool != true,
                  let type = event["type"]?.string, type == "user" || type == "assistant",
                  let content = event["message"]?["content"]
            else { continue }
            let uuid = event["uuid"]?.string ?? UUID().uuidString

            if let text = content.string {
                if let prompt = visiblePrompt(text) { entries.append(Entry(id: uuid, kind: .user, text: prompt)) }
                continue
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
                        entries.append(Entry(id: id, kind: .assistant, text: text))
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
        return entries
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

    /// Hides harness-injected messages (command wrappers, reminders, interrupts).
    private static func visiblePrompt(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("<") || t.hasPrefix("[Request interrupted") { return nil }
        return t
    }
}
