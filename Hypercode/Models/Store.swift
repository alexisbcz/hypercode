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

    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        config = RunConfig(
            model: defaults.string(forKey: "model") ?? "default",
            effort: Effort(rawValue: defaults.string(forKey: "effort") ?? "") ?? .high,
            mode: PermissionMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .auto
        )
        models = defaults.data(forKey: "models").flatMap { try? JSONDecoder().decode([ModelOption].self, from: $0) }
            ?? ModelOption.fallback
        fitEffort()
        refreshModels()
        projects = (defaults.stringArray(forKey: "projects") ?? [])
            .map { Project(url: URL(fileURLWithPath: $0, isDirectory: true)) }
        draftProject = projects.first
        selection = defaults.string(forKey: "selection")
        for project in projects { reload(project) }
        refreshLive()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLive() }
        }
        #if DEBUG
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

    private func refreshModels() {
        let claude = Shell.claude, environment = Shell.environment
        Task {
            guard let fresh = await Task.detached(operation: { ClaudeProcess.models(claude: claude, environment: environment) }).value,
                  fresh != models
            else { return }
            models = fresh
            fitEffort()
        }
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
        }
    }

    // MARK: - Sessions

    func newSession(in project: Project? = nil) {
        if let project { draftProject = project }
        selection = nil
    }

    /// Unsent text and attachments, per session ("new" for the new-session composer).
    func draft(for key: String) -> Draft {
        if let draft = drafts[key] { return draft }
        let draft = Draft()
        drafts[key] = draft
        return draft
    }

    func start(_ prompt: String, attachments: [Attachment]) {
        guard let project = draftProject else { return }
        let firstLine = prompt.isEmpty ? (attachments.first?.name ?? "New Session") : prompt
        let title = String(firstLine.prefix(60)).replacingOccurrences(of: "\n", with: " ")
        let session = Session(project: project, title: title)
        sessions[project.id, default: []].append(session)
        selection = session.id
        session.send(prompt, attachments: attachments, config: config)
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

    private func saveProjects() {
        defaults.set(projects.map(\.url.path), forKey: "projects")
    }
}
