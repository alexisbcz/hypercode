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
    enum Kind: Sendable { case user, assistant, thinking, tool, error }

    let id: String
    var kind: Kind
    var text = ""
    var tool: ToolCall?
    var images: [Data] = []
    var files: [String] = []
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
