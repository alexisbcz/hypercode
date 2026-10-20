import Foundation
import Observation

/// Which of Claude Code's settings.json files to edit. Later ones win: a project's settings override yours,
/// and its local settings override the shared ones.
enum SettingsScope: String, CaseIterable, Identifiable {
    case user, project, local
    var id: String { rawValue }

    var label: String {
        switch self {
        case .user: "You"
        case .project: "Project"
        case .local: "Project, Local"
        }
    }

    var summary: String {
        switch self {
        case .user: "Applies to every project, unless a project's settings say otherwise."
        case .project: "Shared with everyone who works on the project: commit it with the code."
        case .local: "Only for you in this project; Claude Code keeps it out of git."
        }
    }

    func url(in project: Project?) -> URL? {
        switch self {
        case .user: ClaudeHome.url.appending(path: "settings.json")
        case .project: project?.url.appending(path: ".claude/settings.json")
        case .local: project?.url.appending(path: ".claude/settings.local.json")
        }
    }
}

enum ClaudeHome {
    static var url: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    }
}

/// One settings.json. Every change re-reads the file first and touches only its own key, because Claude Code
/// writes to these files too (when you pick "always allow", say) and its changes mustn't be lost.
@Observable
final class SettingsFile {
    let url: URL
    private(set) var root: OrderedJSON = .object([])
    /// Set when the file on disk isn't valid JSON; nothing is written over it until it's fixed.
    private(set) var problem: String?
    private(set) var exists = false

    init(url: URL) {
        self.url = url
        reload()
    }

    func reload() {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            exists = false
            problem = nil
            root = .object([])
            return
        }
        exists = true
        let text = String(decoding: data, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problem = nil
            root = .object([])
            return
        }
        do {
            let parsed = try OrderedJSON.parse(text)
            guard parsed.pairs != nil else { throw OrderedJSON.ParseError(message: "The file should hold a { … } object", line: 1) }
            root = parsed
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    subscript(path: String...) -> OrderedJSON? { root.value(at: path) }

    func set(_ value: OrderedJSON?, at path: String...) {
        reload()
        guard problem == nil else { return }
        var updated = root
        updated.set(value, at: path)
        guard updated != root else { return }
        write(updated)
    }

    /// The whole file as text, for the JSON editor.
    var text: String {
        if problem != nil, let data = FileManager.default.contents(atPath: url.path) { return String(decoding: data, as: UTF8.self) }
        return root.formatted()
    }

    /// Replaces the file with edited JSON; throws, leaving the file as it was, if the text doesn't parse.
    func replace(with text: String) throws {
        let parsed = try OrderedJSON.parse(text)
        guard parsed.pairs != nil else { throw OrderedJSON.ParseError(message: "The file should hold a { … } object", line: 1) }
        problem = nil
        write(parsed)
    }

    private func write(_ value: OrderedJSON) {
        // Clearing the last setting of a file that never existed shouldn't create an empty one.
        if !exists, value.pairs?.isEmpty == true { root = value; return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((value.formatted() + "\n").utf8).write(to: url, options: .atomic)
            root = value
            exists = true
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: - Instructions

/// A Markdown file that shapes what Claude does: a CLAUDE.md, a slash command, an agent, a skill, an output style.
struct InstructionFile: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case memory, command, agent, skill, outputStyle

        var title: String {
            switch self {
            case .memory: "Memory"
            case .command: "Commands"
            case .agent: "Agents"
            case .skill: "Skills"
            case .outputStyle: "Output Styles"
            }
        }

        var noun: String {
            switch self {
            case .memory: "Memory"
            case .command: "Command"
            case .agent: "Agent"
            case .skill: "Skill"
            case .outputStyle: "Output Style"
            }
        }

        var symbol: String {
            switch self {
            case .memory: "brain"
            case .command: "slash.circle"
            case .agent: "person.crop.circle"
            case .skill: "wand.and.stars"
            case .outputStyle: "textformat"
            }
        }

        /// The folder under .claude/ the kind lives in.
        var folder: String {
            switch self {
            case .memory: ""
            case .command: "commands"
            case .agent: "agents"
            case .skill: "skills"
            case .outputStyle: "output-styles"
            }
        }

        var explanation: String {
            switch self {
            case .memory: "Instructions Claude reads at the start of every session."
            case .command: "Run as /name in the composer; the file is the prompt sent."
            case .agent: "A subagent Claude can hand work to, with its own prompt and tools."
            case .skill: "Know-how Claude loads when a task calls for it, from its description."
            case .outputStyle: "Changes how Claude writes its replies; pick one with /output-style."
            }
        }
    }

    let kind: Kind
    let url: URL
    /// What the list shows: "CLAUDE.md", "/review", "reviewer"…
    let name: String
    var detail = ""

    var id: URL { url }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    /// Memory files are fixed places; the others can be added and deleted.
    var isRemovable: Bool { kind != .memory }

    /// All instruction files in a .claude folder (yours, or a project's), plus the CLAUDE.md files that would
    /// be read there even when they don't exist yet, so they can be created.
    static func all(in scope: InstructionScope) -> [InstructionFile] {
        var files: [InstructionFile] = []
        switch scope {
        case .user:
            files.append(InstructionFile(kind: .memory, url: ClaudeHome.url.appending(path: "CLAUDE.md"), name: "CLAUDE.md", detail: "For every project"))
        case .project(let project):
            files.append(InstructionFile(kind: .memory, url: project.url.appending(path: "CLAUDE.md"), name: "CLAUDE.md", detail: "Shared with the project"))
            files.append(InstructionFile(kind: .memory, url: project.url.appending(path: "CLAUDE.local.md"), name: "CLAUDE.local.md", detail: "Only for you"))
        }
        let base = scope.claudeFolder
        let fm = FileManager.default
        for kind in [Kind.command, .agent, .outputStyle] {
            let folder = base.appending(path: kind.folder)
            guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            var found: [InstructionFile] = []
            for case let url as URL in enumerator where url.pathExtension == "md" {
                // Commands in subfolders are namespaced: commands/git/commit.md is /git:commit.
                let relative = url.path.dropFirst(folder.path.count + 1).dropLast(3)
                let name = kind == .command ? "/" + relative.replacingOccurrences(of: "/", with: ":") : String(relative)
                found.append(InstructionFile(kind: kind, url: url, name: name))
            }
            files += found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        let skills = base.appending(path: Kind.skill.folder)
        let skillFolders = (try? fm.contentsOfDirectory(at: skills, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        files += skillFolders
            .map { $0.appending(path: "SKILL.md") }
            .filter { fm.fileExists(atPath: $0.path) }
            .map { InstructionFile(kind: .skill, url: $0, name: $0.deletingLastPathComponent().lastPathComponent) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return files
    }

    /// Creates a new file of a kind with a starting template, and returns it.
    static func create(_ kind: Kind, named rawName: String, in scope: InstructionScope) throws -> InstructionFile {
        let name = rawName.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !name.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let folder = scope.claudeFolder.appending(path: kind.folder)
        let url = kind == .skill ? folder.appending(path: "\(name)/SKILL.md") : folder.appending(path: "\(name).md")
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        let template = switch kind {
        case .memory: ""
        case .command: """
            ---
            description: What this command does, shown in the / menu
            ---

            The prompt to send. $ARGUMENTS is replaced by whatever follows the command.

            """
        case .agent: """
            ---
            name: \(name)
            description: When Claude should hand work to this agent
            ---

            You are…

            """
        case .skill: """
            ---
            name: \(name)
            description: What this skill helps with, and when Claude should use it
            ---

            # \(rawName.trimmingCharacters(in: .whitespaces))

            """
        case .outputStyle: """
            ---
            name: \(rawName.trimmingCharacters(in: .whitespaces))
            description: How replies in this style read
            ---

            Write replies that…

            """
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(template.utf8).write(to: url)
        let shown = kind == .command ? "/" + name : name
        return InstructionFile(kind: kind, url: url, name: shown)
    }

    /// Moves the file (a skill's whole folder) to the Trash, so a slip can be undone from Finder.
    func trash() throws {
        let target = kind == .skill ? url.deletingLastPathComponent() : url
        try FileManager.default.trashItem(at: target, resultingItemURL: nil)
    }
}

enum InstructionScope: Hashable {
    case user
    case project(Project)

    var claudeFolder: URL {
        switch self {
        case .user: ClaudeHome.url
        case .project(let project): project.url.appending(path: ".claude")
        }
    }
}
