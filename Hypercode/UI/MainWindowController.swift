import AppKit

/// The main window: sidebar and detail in a split view, under a unified toolbar.
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    let store: Store
    private let split = NSSplitViewController()
    private let detail: DetailViewController
    private var observer: Observer?

    init(store: Store) {
        self.store = store
        detail = DetailViewController(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Hypercode"
        window.minSize = NSSize(width: 760, height: 480)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let sidebar = NSSplitViewItem(sidebarWithViewController: SidebarViewController(store: store))
        sidebar.minimumThickness = 220
        sidebar.maximumThickness = 360
        sidebar.canCollapse = true
        let content = NSSplitViewItem(viewController: detail)
        content.minimumThickness = 480
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(content)
        split.splitView.autosaveName = "MainSplit"
        window.contentViewController = split

        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.delegate = self
        window.setContentSize(NSSize(width: 1100, height: 760))
        window.setFrameAutosaveName("Main")
        if !window.setFrameUsingName("Main") { window.center() }

        observer = Observer { [weak self] in self?.syncTitle() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func syncTitle() {
        if let session = store.selectedSession {
            window?.title = session.title
            window?.subtitle = session.project.name
        } else {
            window?.title = "New Session"
            window?.subtitle = store.draftProject?.name ?? ""
        }
    }

    var composer: ComposerView? { detail.composer }
    var selectedSession: Session? { store.selectedSession }

    // MARK: - Toolbar

    private static let newSession = NSToolbarItem.Identifier("newSession")
    private static let terminal = NSToolbarItem.Identifier("terminal")
    private static let finder = NSToolbarItem.Identifier("finder")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, Self.newSession, .sidebarTrackingSeparator, .flexibleSpace, Self.terminal, Self.finder]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.isBordered = true
        item.target = self
        switch id {
        case Self.newSession:
            item.label = "New Session"
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New Session")
            item.action = #selector(newSession)
        case Self.terminal:
            item.label = "Open in Terminal"
            item.image = NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: "Open in Terminal")
            item.action = #selector(openTerminal)
        case Self.finder:
            item.label = "Show in Finder"
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Show in Finder")
            item.action = #selector(showInFinder)
        default:
            return nil
        }
        item.toolTip = item.label
        return item
    }

    @objc func newSession() { store.newSession(in: store.selectedSession?.project) }

    @objc private func openTerminal() {
        guard let project = store.selectedSession?.project ?? store.draftProject else { return }
        store.openTerminal(in: project)
    }

    @objc private func showInFinder() {
        guard let project = store.selectedSession?.project ?? store.draftProject else { return }
        NSWorkspace.shared.activateFileViewerSelecting([project.url])
    }
}

/// Shows the selected session, or the new-session screen, swapping only when the selection changes.
final class DetailViewController: NSViewController {
    let store: Store
    private var current: NSViewController?
    private var currentID: String?
    private var observer: Observer?
    /// Recently shown sessions, most recent last. Building a pane (and measuring a long transcript)
    /// costs far more than re-showing one, so switching back is just a view swap.
    private var recent: [SessionViewController] = []
    private static let keptPanes = 8

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        observer = Observer { [weak self] in self?.sync() }
    }

    var composer: ComposerView? {
        (current as? SessionViewController)?.composer ?? (current as? NewSessionViewController)?.composer
    }

    private func sync() {
        let session = store.selectedSession
        let id = session?.id ?? "new"
        guard id != currentID else { return }
        currentID = id
        let next: NSViewController = session.map(pane(for:)) ?? NewSessionViewController(store: store)
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        addChild(next)
        view.addSubview(next.view)
        next.view.pin(to: view)
        current = next
        DispatchQueue.main.async { [weak self] in self?.composer?.focus() }
    }

    private func pane(for session: Session) -> SessionViewController {
        let pane = recent.first { $0.session === session } ?? SessionViewController(store: store, session: session)
        recent.removeAll { $0 === pane }
        recent.append(pane)
        // Trashed or removed sessions don't need their pane any more.
        let live = Set(store.sessions.values.joined().map(\.id))
        recent.removeAll { !live.contains($0.session.id) && $0 !== pane }
        if recent.count > Self.keptPanes { recent.removeFirst(recent.count - Self.keptPanes) }
        return pane
    }
}
