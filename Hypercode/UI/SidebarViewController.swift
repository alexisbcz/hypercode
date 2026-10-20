import AppKit

/// Projects as source-list groups, each with its five latest sessions (and "Show More"), plus search.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSSearchFieldDelegate, NSTextFieldDelegate {
    let store: Store

    private final class Group {
        let project: Project
        var rows: [AnyObject] = []
        init(project: Project) { self.project = project }
    }

    private final class More {
        let projectID: String
        let title: String
        init(projectID: String, title: String) {
            self.projectID = projectID
            self.title = title
        }
    }

    private let outline = NSOutlineView()
    private let search = NSSearchField()
    private let empty = NSStackView()
    private var groups: [Group] = []
    private var groupCache: [String: Group] = [:]
    private var expanded: Set<String> = []
    private var observer: Observer?
    private var isSyncingSelection = false
    private var renaming: Session?
    private var clock: Timer?

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()

        search.placeholderString = "Search"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 0
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let open = NSButton(title: "Open Project…", image: .symbol("folder.badge.plus", size: 13), target: self, action: #selector(openProject))
        open.isBordered = false
        open.imagePosition = .imageLeading
        open.contentTintColor = .secondaryLabelColor
        open.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField.label("No Projects", font: .systemFont(ofSize: 15, weight: .semibold))
        let message = NSTextField(wrappingLabelWithString: "Open a folder to start working with Claude.")
        message.alignment = .center
        message.textColor = .secondaryLabelColor
        let button = NSButton(title: "Open Project…", target: self, action: #selector(openProject))
        empty.setViews([NSImageView(image: .symbol("folder", size: 28)), title, message, button], in: .center)
        empty.orientation = .vertical
        empty.spacing = 8
        empty.translatesAutoresizingMaskIntoConstraints = false

        for view in [scroll, search, open, empty] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 6),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: open.topAnchor, constant: -6),
            open.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            open.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -32),
        ])
        view = root

        store.focusSearch = { [weak self] in
            guard let self else { return }
            view.window?.makeFirstResponder(search)
        }
        observer = Observer { [weak self] in self?.sync() }
        // Relative dates ("5m") age while the window is open.
        clock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<(self?.outline.numberOfRows ?? 0)), columnIndexes: [0]) }
        }
    }

    // MARK: - Sync

    private func sync() {
        let query = search.stringValue
        var fresh: [Group] = []
        for project in store.projects {
            let group = groupCache[project.id] ?? Group(project: project)
            groupCache[project.id] = group
            let all = store.sessions(in: project).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            let showAll = expanded.contains(project.id) || !query.isEmpty
            var rows: [AnyObject] = showAll ? all : Array(all.prefix(5))
            // Read what rows draw, so a title, date or busy change redraws the sidebar.
            for case let session as Session in rows { _ = (session.title, session.date, store.isBusy(session)) }
            if all.count > 5, query.isEmpty {
                rows.append(More(projectID: project.id, title: showAll ? "Show Less" : "Show \(all.count - 5) More"))
            }
            group.rows = rows
            fresh.append(group)
        }
        groups = fresh
        empty.isHidden = !store.projects.isEmpty
        _ = store.selection
        guard renaming == nil else { return }
        outline.reloadData()
        for group in groups { outline.expandItem(group) }
        syncSelection()
    }

    private func syncSelection() {
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        let row = store.selectedSession.map { outline.row(forItem: $0) } ?? -1
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        } else {
            outline.deselectAll(nil)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === search { sync() }
    }

    @objc private func openProject() { store.openProject() }

    // MARK: - Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return groups.count }
        return (item as? Group)?.rows.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return groups[index] }
        return (item as! Group).rows[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is Group }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is Group }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is Session }
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is Group ? 28 : 26
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard item is Session else { return nil }
        let row = outlineView.makeView(withIdentifier: SourceRowView.identifier, owner: nil) as? SourceRowView ?? SourceRowView()
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        switch item {
        case let group as Group:
            let cell = outlineView.makeView(withIdentifier: ProjectCell.identifier, owner: nil) as? ProjectCell ?? ProjectCell()
            cell.configure(group.project) { [weak self] in self?.store.newSession(in: group.project) }
            return cell
        case let session as Session:
            let cell = outlineView.makeView(withIdentifier: SessionCell.identifier, owner: nil) as? SessionCell ?? SessionCell()
            cell.configure(session, busy: store.isBusy(session))
            cell.textField?.delegate = self
            return cell
        case let more as More:
            let cell = outlineView.makeView(withIdentifier: SessionCell.moreIdentifier, owner: nil) as? NSTableCellView ?? SessionCell.more()
            cell.textField?.stringValue = more.title
            return cell
        default:
            return nil
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, let session = outline.item(atRow: outline.selectedRow) as? Session else { return }
        if store.selection != session.id { store.selection = session.id }
    }

    @objc private func clicked() {
        guard let more = outline.item(atRow: outline.clickedRow) as? More else { return }
        if expanded.contains(more.projectID) { expanded.remove(more.projectID) } else { expanded.insert(more.projectID) }
        sync()
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let item = outline.item(atRow: outline.clickedRow)
        if let group = item as? Group {
            let project = group.project
            menu.addItem(MenuAction.item("New Session") { [weak self] in self?.store.newSession(in: project) })
            menu.addItem(MenuAction.item("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) })
            menu.addItem(.separator())
            menu.addItem(MenuAction.item("Remove Project") { [weak self] in self?.store.removeProject(project) })
        } else if let session = item as? Session {
            menu.addItem(MenuAction.item("Rename…") { [weak self] in self?.beginRename(session) })
            menu.addItem(MenuAction.item("Resume in Terminal") { [weak self] in self?.store.resumeInTerminal(session) })
            menu.addItem(.separator())
            menu.addItem(MenuAction.item("Copy Session ID") { copyToPasteboard(session.id) })
            menu.addItem(MenuAction.item("Copy Resume Command") { copyToPasteboard("claude --resume \(session.id)") })
            menu.addItem(MenuAction.item("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([Transcript.file(for: session.project.url, session: session.id)])
            })
            menu.addItem(.separator())
            menu.addItem(MenuAction.item("Move to Trash") { [weak self] in self?.store.trash(session) })
        }
    }

    // MARK: - Rename in place

    private func beginRename(_ session: Session) {
        let row = outline.row(forItem: session)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SessionCell,
              let field = cell.textField
        else { return }
        renaming = session
        field.isEditable = true
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field !== search, let session = renaming else { return }
        field.isEditable = false
        renaming = nil
        let cancelled = (notification.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.cancel.rawValue
        if !cancelled { store.rename(session, to: field.stringValue) }
        sync()
    }
}

private final class ProjectCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("project")
    private let label = NSTextField.label(font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
    private var onAdd: () -> Void = {}
    private lazy var add = ActionButton(symbol: "plus", size: 11, weight: .semibold, label: "New Session") { [weak self] in self?.onAdd() }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        add.contentTintColor = .secondaryLabelColor
        for view in [label, add] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: add.leadingAnchor, constant: -6),
            add.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            add.centerYAnchor.constraint(equalTo: centerYAnchor),
            add.widthAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ project: Project, onAdd: @escaping () -> Void) {
        label.stringValue = project.name
        add.toolTip = "New Session in \(project.name)"
        self.onAdd = onAdd
    }
}

private final class SessionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("session")
    static let moreIdentifier = NSUserInterfaceItemIdentifier("more")
    /// "now", "5m", "3h", "2d", then the date: short enough to sit beside a title.
    private static func age(of date: Date) -> String {
        let seconds = max(0, Date.now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        case ..<(7 * 86400): return "\(Int(seconds / 86400))d"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    private let date = NSTextField.label(font: .systemFont(ofSize: 11), color: .tertiaryLabelColor)
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let title = NSTextField.label()
        title.isEditable = false
        title.focusRingType = .none
        textField = title
        spinner.style = .spinning
        spinner.controlSize = .mini
        date.setContentCompressionResistancePriority(.required, for: .horizontal)
        date.setContentHuggingPriority(.required, for: .horizontal)
        for view in [title, date, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: date.leadingAnchor, constant: -6),
            date.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            date.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    static func more() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = moreIdentifier
        let label = NSTextField.label(color: .secondaryLabelColor)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func configure(_ session: Session, busy: Bool) {
        textField?.stringValue = session.title
        textField?.toolTip = session.title
        date.stringValue = Self.age(of: session.date)
        date.isHidden = busy
        spinner.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
}

/// A selected row stays accent blue while the window is active, even when the composer has keyboard focus
/// (AppKit would gray it), and goes gray only when the window isn't key.
private final class SourceRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("sourceRow")
    private var isWindowKey = false
    private var tokens: [any NSObjectProtocol] = []

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isEmphasized: Bool {
        get { isWindowKey }
        set { super.isEmphasized = isWindowKey }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
        guard let window else { return }
        refresh()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    private func refresh() {
        isWindowKey = window?.isKeyWindow ?? false
        isEmphasized = isWindowKey
        needsDisplay = true
    }
}
