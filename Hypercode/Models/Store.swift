import AppKit
import Observation

@Observable
final class Store {
    var projects: [Project] = [] { didSet { saveProjects() } }
    var sessions: [String: [Session]] = [:]
    var selection: String? { didSet { defaults.set(selection, forKey: "selection") } }
    var draftProject: Project?
    /// Sessions a `claude` process outside this app is working on right now.
    private(set) var busyElsewhere: Set<String> = []
    @ObservationIgnored private var drafts: [String: Draft] = [:]
    @ObservationIgnored private var liveTimer: Timer?

    var config: RunConfig {
        didSet {
            defaults.set(config.model, forKey: "model")
            if let effort = config.effort { defaults.set(effort.rawValue, forKey: "effort") }
            defaults.set(config.mode.rawValue, forKey: "mode")
        }
    }
    /// What `/model` lists, cached so the menu is complete before the CLI answers.
    private(set) var models: [ModelOption] {
        didSet { defaults.set(try? JSONEncoder().encode(models), forKey: "models") }
    }
    /// Slash commands and skills per project (project skills and commands differ), cached across launches.
    private(set) var commands: [String: [SlashCommand]] {
        didSet { defaults.set(try? JSONEncoder().encode(commands), forKey: "commands") }
    }
    /// Commands that need the interactive terminal UI, as each process's init event reports them.
    private(set) var terminalCommands: Set<String> = ["doctor", "color", "focus", "reload-plugins"]
    /// The reply to a command run from the new-session screen, where there's no transcript to show it in.
    var newSessionNotice: String?
    /// Asks the sidebar to focus its search field (`/resume`).
    @ObservationIgnored var focusSearch: () -> Void = {}
    @ObservationIgnored private var loadingCommands: Set<String> = []

    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        config = RunConfig(
            model: defaults.string(forKey: "model") ?? "default",
            effort: Effort(rawValue: defaults.string(forKey: "effort") ?? "") ?? .high,
            mode: PermissionMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .auto
        )
        models = defaults.data(forKey: "models").flatMap { try? JSONDecoder().decode([ModelOption].self, from: $0) }
            ?? ModelOption.fallback
        commands = defaults.data(forKey: "commands").flatMap { try? JSONDecoder().decode([String: [SlashCommand]].self, from: $0) } ?? [:]
        fitEffort()
        projects = (defaults.stringArray(forKey: "projects") ?? [])
            .map { Project(url: URL(fileURLWithPath: $0, isDirectory: true)) }
        draftProject = projects.first
        selection = defaults.string(forKey: "selection")
        for project in projects { reload(project) }
        // One `initialize` answers both models and commands; any project will do for models.
        loadCommands(for: selectedSession?.project ?? draftProject)
        Session.didInitialize = { [weak self] event in
            let terminal = Set((event["terminal_slash_commands"]?.array ?? []).compactMap(\.string))
            if !terminal.isEmpty, terminal != self?.terminalCommands { self?.terminalCommands = terminal }
        }
        refreshLive()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLive() }
        }
        #if DEBUG
        // HYPERCODE_REPLAY=<stream-json file> replays a recorded reply and reports main-thread stalls; see Bench.
        Bench.replayIfRequested(into: self)
        // HYPERCODE_TTS_FILE=<out.wav> times Pocket TTS on a sample reply and writes it out; see Bench.
        Bench.synthesizeIfRequested()
        // HYPERCODE_SNAPSHOT=<out.png> saves the windows as images and quits; see Bench.
        Bench.snapshotIfRequested()
        // HYPERCODE_ATTACH=a.png:b.txt pre-attaches files, for checking the composer by eye.
        if let paths = ProcessInfo.processInfo.environment["HYPERCODE_ATTACH"] {
            draft(for: selection ?? "new").add(paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
        }
        #endif
    }

    var selectedSession: Session? {
        guard let selection else { return nil }
        return sessions.values.lazy.flatMap { $0 }.first { $0.id == selection }
    }

    func sessions(in project: Project) -> [Session] {
        (sessions[project.id] ?? []).sorted { $0.date > $1.date }
    }

    // MARK: - Models

    var model: ModelOption {
        models.first { $0.value == config.model } ?? ModelOption(value: config.model, displayName: config.model)
    }

    var efforts: [Effort] {
        Effort.allCases.filter { model.effortLevels.contains($0.rawValue) }
    }

    func selectModel(_ value: String) {
        config.model = value
        fitEffort()
    }

    /// Keeps the effort to one the model takes: the saved one when it can, else the nearest below it.
    private func fitEffort() {
        let levels = efforts
        guard !levels.isEmpty else {
            if config.effort != nil { config.effort = nil }
            return
        }
        if let effort = config.effort, levels.contains(effort) { return }
        let wanted = Effort(rawValue: defaults.string(forKey: "effort") ?? "") ?? .high
        config.effort = levels.contains(wanted) ? wanted : levels.last { $0.rank < wanted.rank } ?? levels[0]
    }

    // MARK: - Commands

    /// Every command for the project, app-handled ones included, in the CLI's order.
    func commands(for project: Project?) -> [SlashCommand] {
        let listed = project.flatMap { commands[$0.id] } ?? SlashCommand.fallback
        let extra = SlashCommand.appCommands.filter { app in !listed.contains { $0.matches(app.name) } }
        return listed + extra
    }

    /// Asks the CLI (once per launch per project) which commands and models are available there.
    func loadCommands(for project: Project?) {
        let key = project?.id ?? "~"
        guard loadingCommands.insert(key).inserted else { return }
        let claude = Shell.claude, environment = Shell.environment
        let cwd = project?.url ?? FileManager.default.homeDirectoryForCurrentUser
        Task {
            guard let reply = await Task.detached(operation: {
                ClaudeProcess.initialize(claude: claude, environment: environment, cwd: cwd)
            }).value else {
                loadingCommands.remove(key)
                return
            }
            let fresh = (reply["models"]?.array ?? []).compactMap(ModelOption.init)
            if !fresh.isEmpty, fresh != models {
                models = fresh
                fitEffort()
            }
            let listed = (reply["commands"]?.array ?? []).compactMap(SlashCommand.init)
            if let project, !listed.isEmpty, commands[project.id] != listed { commands[project.id] = listed }
        }
    }

    /// Sends what the composer holds, running slash commands the app owns (/clear, /model, /help…) itself.
    func submit(_ text: String, attachments: [Attachment], in session: Session?) {
        // You're talking again; a reply still being read aloud would talk over you.
        Speaker.shared.stop()
        let project = session?.project ?? draftProject
        guard text.hasPrefix("/"), attachments.isEmpty, let project else {
            return send(text, attachments: attachments, in: session, isCommand: false)
        }
        let body = text.dropFirst()
        let name = String(body.prefix { !$0.isWhitespace })
        let args = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let command = commands(for: project).first(where: { $0.matches(name) }) else {
            // Not a command we know; "/usr/bin is slow" is a fine prompt.
            return send(text, attachments: attachments, in: session, isCommand: false)
        }
        if run(command, args: args, project: project, session: session) { return }
        send(text, attachments: [], in: session, isCommand: true)
    }

    private func send(_ text: String, attachments: [Attachment], in session: Session?, isCommand: Bool) {
        newSessionNotice = nil
        if let session {
            session.send(text, attachments: attachments, config: config, isCommand: isCommand)
        } else {
            start(text, attachments: attachments, isCommand: isCommand)
        }
    }

    /// Runs a command the app owns. False hands it to the CLI.
    private func run(_ command: SlashCommand, args: String, project: Project, session: Session?) -> Bool {
        let notify: (String) -> Void = { [weak self] text in
            if let session { session.appendNotice(text) } else { self?.newSessionNotice = text }
        }
        switch command.name {
        case "clear":
            // Same as the CLI: the old session stays on disk and in the sidebar.
            newSession(in: project)
            return true
        case "model":
            guard !args.isEmpty else {
                notify("Current model: **\(model.shortLabel)**. Pick another from the menu below the composer, or run `/model <name>`.")
                return true
            }
            let wanted = args.lowercased()
            let match = models.first { $0.value.lowercased() == wanted || $0.displayName.lowercased() == wanted }
                ?? models.first { $0.displayName.lowercased().hasPrefix(wanted) }
            selectModel(match?.value ?? args)
            notify("Model set to **\(model.shortLabel)**")
            return true
        case "effort":
            guard let effort = Effort(rawValue: args.lowercased()) else { return false }
            guard efforts.contains(effort) else {
                notify("\(model.shortLabel) doesn't take an effort of \(effort.label).")
                return true
            }
            config.effort = effort
            defaults.set(effort.rawValue, forKey: "effort")
            notify("Effort set to **\(effort.label)**")
            return true
        case "rename":
            guard let session else { return true }
            guard !args.isEmpty else { return false }
            rename(session, to: args)
            notify("Renamed to **\(args)**")
            return true
        case "help":
            notify(help(for: project))
            return true
        case "resume":
            focusSearch()
            return true
        case "exit", "quit":
            return true
        default:
            guard terminalCommands.contains(command.name) else { return false }
            if let session { resumeInTerminal(session) } else { openTerminal(in: project) }
            notify("`/\(command.name)` needs Claude Code's terminal interface, so it opened in Terminal.")
            return true
        }
    }

    private func help(for project: Project) -> String {
        func lines(_ list: [SlashCommand]) -> String {
            list.map { c in
                let hint = c.argumentHint.isEmpty ? "" : " " + c.argumentHint
                let description = c.description.count > 120 ? c.description.prefix(117) + "…" : Substring(c.description)
                return "- `/\(c.name)\(hint)` — \(description)"
            }.joined(separator: "\n")
        }
        let all = commands(for: project)
        let builtins = all.filter(\.isBuiltin), skills = all.filter { !$0.isBuiltin }
        var text = "### Commands\n\n" + lines(builtins)
        if !skills.isEmpty { text += "\n\n### Skills and custom commands\n\n" + lines(skills) }
        return text + "\n\nType `/` in the composer to search them."
    }

    func isBusy(_ session: Session) -> Bool {
        session.isRunning || busyElsewhere.contains(session.id)
    }

    private func refreshLive() {
        Task {
            let busy = await Task.detached { LiveSessions.busy() }.value
            // Assigning an equal set would still invalidate every row.
            if busy != busyElsewhere { busyElsewhere = busy }
        }
    }

    // MARK: - Projects

    func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        // "New Folder" in the panel: a new project starts here.
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "Choose a project folder for Claude to work in."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProject(url)
    }

    func addProject(_ url: URL) {
        let project = Project(url: url)
        if !projects.contains(project) {
            projects.insert(project, at: 0)
            reload(project)
        }
        loadCommands(for: project)
        newSession(in: project)
    }

    func removeProject(_ project: Project) {
        projects.removeAll { $0 == project }
        sessions[project.id] = nil
        if draftProject == project { draftProject = projects.first }
        if selectedSession?.project == project { selection = nil }
    }

    func reload(_ project: Project) {
        Task {
            let summaries = await Task.detached { Transcript.summaries(for: project.url) }.value
            let live = (sessions[project.id] ?? []).filter { s in !summaries.contains { $0.id == s.id } }
            let existing = Dictionary((sessions[project.id] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            sessions[project.id] = live + summaries.map { existing[$0.id] ?? Session(project: project, summary: $0) }
            // Parse the likeliest next picks ahead of time, so opening one doesn't wait on a long file.
            for session in self.sessions(in: project).prefix(3) {
                Task(priority: .utility) { await session.loadIfNeeded() }
            }
        }
    }

    // MARK: - Sessions

    func newSession(in project: Project? = nil) {
        if let project { draftProject = project }
        selection = nil
        newSessionNotice = nil
    }

    /// Unsent text and attachments, per session ("new" for the new-session composer).
    func draft(for key: String) -> Draft {
        if let draft = drafts[key] { return draft }
        let draft = Draft()
        drafts[key] = draft
        return draft
    }

    func start(_ prompt: String, attachments: [Attachment], isCommand: Bool = false) {
        guard let project = draftProject else { return }
        let firstLine = prompt.isEmpty ? (attachments.first?.name ?? "New Session") : prompt
        let title = String(firstLine.prefix(60)).replacingOccurrences(of: "\n", with: " ")
        let session = Session(project: project, title: title)
        sessions[project.id, default: []].append(session)
        selection = session.id
        session.send(prompt, attachments: attachments, config: config, isCommand: isCommand)
    }

    func rename(_ session: Session, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        session.title = title
        // Same record `/rename` writes, so the CLI picks the name up too.
        Transcript.appendTitle(title, to: Transcript.file(for: session.project.url, session: session.id), session: session.id)
    }

    func trash(_ session: Session) {
        session.stop()
        let file = Transcript.file(for: session.project.url, session: session.id)
        try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
        sessions[session.project.id]?.removeAll { $0.id == session.id }
        if selection == session.id { newSession(in: session.project) }
    }

    func resumeInTerminal(_ session: Session) {
        let script = FileManager.default.temporaryDirectory.appending(path: "hypercode-\(session.id).command")
        let path = session.project.url.path.replacingOccurrences(of: "'", with: "'\\''")
        let contents = "#!/bin/zsh -l\ncd '\(path)' && exec \(Shell.claude.path) --resume \(session.id)\n"
        guard (try? contents.write(to: script, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    func openTerminal(in project: Project) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([project.url], withApplicationAt: terminal, configuration: .init(), completionHandler: nil)
    }

    private func saveProjects() {
        defaults.set(projects.map(\.url.path), forKey: "projects")
    }
}
