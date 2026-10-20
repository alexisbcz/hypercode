import Foundation

nonisolated struct Project: Identifiable, Hashable, Sendable {
    let url: URL
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

nonisolated struct ToolCall: Sendable {
    var name: String
    var input: JSON?
    var result: String?
    var isError = false

    var symbol: String {
        switch name {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": "pencil"
        case "Grep", "Glob", "ToolSearch": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task", "Agent": "person.2"
        case "TodoWrite": "checklist"
        case "Skill": "sparkles"
        default: name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }

    var title: String {
        switch name {
        case "Bash": "Ran"
        case "Read": "Read"
        case "Edit", "MultiEdit": "Edited"
        case "Write": "Wrote"
        case "Grep", "Glob": "Searched"
        case "WebFetch": "Fetched"
        case "WebSearch": "Searched the web"
        case "Task", "Agent": "Agent"
        case "TodoWrite": "Updated todos"
        default: name.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "__", with: " · ")
        }
    }

    var summary: String {
        guard let input else { return "" }
        let path = input["file_path"]?.string ?? input["notebook_path"]?.string
        return input["command"]?.string
            ?? path.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? input["pattern"]?.string
            ?? input["url"]?.string
            ?? input["query"]?.string
            ?? input["description"]?.string
            ?? input["skill"]?.string
            ?? ""
    }
}

nonisolated struct Entry: Identifiable, Sendable {
    /// `command` is a slash command the user ran ("/context"); `notice` is what a command printed,
    /// or a note from the app or harness ("Conversation compacted").
    enum Kind: Sendable { case user, assistant, thinking, tool, error, command, notice }

    let id: String
    var kind: Kind
    var text = ""
    var tool: ToolCall?
    var images: [Data] = []
    var files: [String] = []
}

extension Entry {
    /// Cheap fingerprint of everything a row draws, so the transcript redraws only rows that changed.
    var revision: Int {
        var hasher = Hasher()
        hasher.combine(kind)
        hasher.combine(text.utf8.count)
        hasher.combine(images.count)
        hasher.combine(files.count)
        if let tool {
            hasher.combine(tool.input != nil)
            hasher.combine(tool.result?.utf8.count ?? -1)
            hasher.combine(tool.isError)
        }
        return hasher.finalize()
    }
}

nonisolated struct SessionSummary: Sendable {
    let id: String
    let title: String
    let date: Date
}

enum PermissionMode: String, CaseIterable, Identifiable {
    case auto, acceptEdits, plan, bypassPermissions
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Auto"
        case .acceptEdits: "Accept Edits"
        case .plan: "Plan"
        case .bypassPermissions: "Bypass Permissions"
        }
    }
}

/// A model as `/model` lists it, from the CLI's `initialize` reply.
nonisolated struct ModelOption: Identifiable, Hashable, Codable, Sendable {
    /// What `--model` takes: an alias ("opus") or a full ID ("claude-opus-4-6").
    let value: String
    let displayName: String
    var description = ""
    /// Empty when the model takes no `--effort`, like Haiku 4.5.
    var effortLevels: [String] = []

    var id: String { value }

    /// The footer says which model "Default" is right now, e.g. "Default (Opus 5.5)".
    var shortLabel: String {
        guard value == "default", let resolved = description.components(separatedBy: " · ").first, !resolved.isEmpty
        else { return displayName }
        return "Default (\(resolved))"
    }

    init(value: String, displayName: String, description: String = "", effortLevels: [String] = []) {
        self.value = value
        self.displayName = displayName
        self.description = description
        self.effortLevels = effortLevels
    }

    init?(_ json: JSON) {
        guard let value = json["value"]?.string else { return nil }
        self.value = value
        displayName = json["displayName"]?.string ?? value
        description = json["description"]?.string ?? ""
        effortLevels = json["supportsEffort"]?.bool == true
            ? (json["supportedEffortLevels"]?.array ?? []).compactMap(\.string)
            : []
    }

    /// Until the CLI has answered once.
    static let fallback: [ModelOption] = [
        ("default", "Default (recommended)"), ("opus", "Opus"), ("fable", "Fable"), ("sonnet", "Sonnet"), ("haiku", "Haiku"),
    ].map { ModelOption(value: $0, displayName: $1, effortLevels: Effort.allCases.map(\.rawValue)) }
}

enum Effort: String, CaseIterable, Identifiable {
    case low, medium, high, xhigh, max
    var id: String { rawValue }
    var label: String { self == .xhigh ? "Extra High" : rawValue.capitalized }
    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

struct RunConfig: Equatable {
    var model: String
    /// Nil for a model that takes no effort level.
    var effort: Effort?
    var mode: PermissionMode
}

/// A slash command as the CLI's `initialize` reply lists it: built-ins, skills, plugin and project commands.
nonisolated struct SlashCommand: Identifiable, Hashable, Codable, Sendable {
    let name: String
    var description = ""
    var argumentHint = ""
    var aliases: [String] = []
    var isBuiltin = false

    var id: String { name }
    var takesArguments: Bool { !argumentHint.isEmpty }

    init(name: String, description: String = "", argumentHint: String = "", aliases: [String] = [], isBuiltin: Bool = true) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.aliases = aliases
        self.isBuiltin = isBuiltin
    }

    init?(_ json: JSON) {
        guard let name = json["name"]?.string, !name.hasPrefix("__") else { return nil }
        let description = json["description"]?.string ?? ""
        // Tombstones the CLI keeps for muscle memory.
        if description.hasPrefix("(removed)") || description.hasPrefix("Renamed to") { return nil }
        self.name = name
        self.description = description.components(separatedBy: "\n").first ?? description
        argumentHint = json["argumentHint"]?.string ?? ""
        aliases = (json["aliases"]?.array ?? []).compactMap(\.string)
        isBuiltin = json["builtin"]?.bool ?? false
    }

    func matches(_ name: String) -> Bool {
        self.name == name || aliases.contains(name)
    }

    /// Commands the app runs itself, merged in when the CLI doesn't list them.
    static let appCommands: [SlashCommand] = [
        SlashCommand(name: "help", description: "Show every command and skill you can run here"),
        SlashCommand(name: "resume", description: "Find an earlier session in the sidebar", aliases: ["continue"]),
    ]

    /// Until the CLI has answered once for a project.
    static let fallback: [SlashCommand] = appCommands + [
        SlashCommand(name: "clear", description: "Start a new session with empty context", aliases: ["reset", "new"]),
        SlashCommand(name: "compact", description: "Free up context by summarizing the conversation so far", argumentHint: "<optional custom summarization instructions>"),
        SlashCommand(name: "context", description: "Show current context usage"),
        SlashCommand(name: "model", description: "Set the AI model for Claude Code", argumentHint: "<model>"),
        SlashCommand(name: "effort", description: "Set effort level for model usage", argumentHint: "<low|medium|high|xhigh|max>"),
        SlashCommand(name: "rename", description: "Rename the current conversation", argumentHint: "[name]", aliases: ["name"]),
        SlashCommand(name: "usage", description: "Show session cost, plan usage, and what's contributing to your limits", aliases: ["cost", "stats"]),
        SlashCommand(name: "init", description: "Initialize a new CLAUDE.md file with codebase documentation"),
    ]
}
