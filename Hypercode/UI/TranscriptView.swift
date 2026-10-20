import AppKit

/// The conversation as a view-based table: rows are recycled, heights are measured once per text revision
/// and width, and a streaming reply only re-lays out its own row, once per main-queue turn.
final class TranscriptView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let maxColumnWidth: CGFloat = 760
    static let margin: CGFloat = 24

    let session: Session
    private let scrollView = NSScrollView()
    private let tableView = TranscriptTableView()

    private var entries: [Entry] = []
    private var revisions: [Int] = []
    private var isRunning = false
    private var showsActivity = false
    private var status: String?
    private var expanded: Set<String> = []
    private var bodies: [String: (revision: Int, text: RenderedText)] = [:]
    private var details: [String: (revision: Int, text: RenderedText)] = [:]
    private var heights: [String: (key: Int, height: CGFloat)] = [:]
    private var images: [String: [NSImage]] = [:]
    private var columnWidth: CGFloat = 0
    private var darkMode = false
    private var observer: Observer?
    private var hasScrolledInitially = false

    /// Room for the composer floating over the bottom of the transcript.
    var bottomInset: CGFloat = 0 {
        didSet { if bottomInset != oldValue { updateInsets() } }
    }

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)

        let column = NSTableColumn(identifier: .init("entry"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.usesAutomaticRowHeights = false
        tableView.allowsColumnSelection = false
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        scrollView.pin(to: self)

        darkMode = isDark
        observer = Observer { [weak self] in self?.sync() }
    }

    required init?(coder: NSCoder) { fatalError() }


    // MARK: - Sync

    private func sync() {
        let new = session.entries
        let running = session.isRunning
        let status = session.status
        let activity = running && (status != nil || new.last?.kind != .assistant)
        apply(new, running: running, activity: activity, status: status)
    }

    private func apply(_ new: [Entry], running: Bool, activity: Bool, status: String?) {
        let following = isNearBottom
        let newRevisions = new.map(\.revision)
        let oldCount = entries.count
        let structural = new.count < oldCount || zip(entries, new).contains { $0.id != $1.id }
        let runningChanged = running != isRunning
        let hadActivity = showsActivity
        self.status = status

        if structural || oldCount == 0 {
            entries = new
            revisions = newRevisions
            isRunning = running
            showsActivity = activity
            tableView.reloadData()
        } else {
            var changed = IndexSet((0..<oldCount).filter { revisions[$0] != newRevisions[$0] })
            // The reply that just finished gets its code colored.
            if runningChanged, oldCount > 0 { changed.insert(oldCount - 1) }
            entries = new
            revisions = newRevisions
            isRunning = running

            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            tableView.beginUpdates()
            if hadActivity { tableView.removeRows(at: IndexSet(integer: oldCount), withAnimation: []) }
            if new.count > oldCount { tableView.insertRows(at: IndexSet(oldCount..<new.count), withAnimation: []) }
            showsActivity = activity
            if activity { tableView.insertRows(at: IndexSet(integer: new.count), withAnimation: []) }
            if !changed.isEmpty {
                tableView.noteHeightOfRows(withIndexesChanged: changed)
                for row in changed { refreshVisibleRow(row) }
            }
            tableView.endUpdates()
            NSAnimationContext.endGrouping()
        }

        if !hasScrolledInitially, !entries.isEmpty {
            hasScrolledInitially = true
            layoutSubtreeIfNeeded()
            scrollToBottom()
        } else if following {
            scrollToBottom()
        }
    }

    private func refreshVisibleRow(_ row: Int) {
        guard row < entries.count, let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? EntryCell else { return }
        configure(cell, row: row)
    }

    // MARK: - Scrolling

    private var isNearBottom: Bool {
        let clip = scrollView.contentView
        return clip.bounds.maxY >= tableView.frame.height + scrollView.contentInsets.bottom - 60
    }

    func scrollToBottom() {
        let clip = scrollView.contentView
        let y = max(-scrollView.contentInsets.top, tableView.frame.height + scrollView.contentInsets.bottom - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    private func updateInsets() {
        let following = isNearBottom
        scrollView.contentInsets = NSEdgeInsets(top: safeAreaInsets.top + 20, left: 0, bottom: bottomInset + 20, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        if following { scrollToBottom() }
    }

    override func layout() {
        super.layout()
        let insets = scrollView.contentInsets
        if insets.top != safeAreaInsets.top + 20 { updateInsets() }
        let width = Self.column(for: tableView.bounds.width).width
        guard width != columnWidth, width > 0 else { return }
        columnWidth = width
        // Mid-resize, only what's on screen is re-measured; the rest catches up when the drag ends.
        let rows = inLiveResize ? tableView.rows(in: tableView.visibleRect) : NSRange(location: 0, length: tableView.numberOfRows)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: Range(rows) ?? 0..<0))
        NSAnimationContext.endGrouping()
        for row in Range(rows) ?? 0..<0 { refreshVisibleRow(row) }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let dark = isDark
        guard dark != darkMode else { return }
        darkMode = dark
        bodies.removeAll()
        details.removeAll()
        tableView.reloadData()
    }

    /// The centered reading column inside a row of `width`.
    static func column(for width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let w = max(100, min(maxColumnWidth, width - margin * 2))
        return (floor((width - w) / 2), w)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count + (showsActivity ? 1 : 0)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let width = tableView.bounds.width > 0 ? tableView.bounds.width : bounds.width
        guard row < entries.count else { return ActivityCell.height }
        let entry = entries[row]
        let top = row == 0 ? 0 : spacing(before: entry, after: entries[row - 1])
        let column = Self.column(for: width).width
        var hasher = Hasher()
        hasher.combine(revisions[row])
        hasher.combine(column)
        hasher.combine(expanded.contains(entry.id))
        hasher.combine(top)
        let key = hasher.finalize()
        if let cached = heights[entry.id] {
            // During a live resize, rows off screen keep their old height until the drag ends.
            if cached.key == key || (inLiveResize && !tableView.rows(in: tableView.visibleRect).contains(row)) {
                return cached.height
            }
        }
        let height = max(1, top + measure(entry, column: column))
        heights[entry.id] = (key, height)
        return height
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else {
            let cell = tableView.makeView(withIdentifier: ActivityCell.identifier, owner: nil) as? ActivityCell ?? ActivityCell()
            cell.status = status
            return cell
        }
        let identifier = EntryCell.identifier(for: entries[row].kind)
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? EntryCell ?? EntryCell(identifier: identifier)
        configure(cell, row: row)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    private func configure(_ cell: EntryCell, row: Int) {
        let entry = entries[row]
        cell.transcript = self
        cell.configure(
            entry: entry,
            top: row == 0 ? 0 : spacing(before: entry, after: entries[row - 1]),
            body: body(for: entry, row: row),
            detail: expanded.contains(entry.id) ? detail(for: entry) : nil,
            images: images(for: entry),
            isExpanded: expanded.contains(entry.id),
            root: session.project.url
        )
        cell.needsLayout = true
    }

    /// Tool calls cluster tightly; a new speaker gets room to breathe.
    private func spacing(before entry: Entry, after previous: Entry) -> CGFloat {
        switch (previous.kind, entry.kind) {
        case (.tool, .tool), (.thinking, .tool), (.tool, .thinking): 6
        case (.command, .notice): 10
        case (_, .user), (.user, _), (_, .command), (.command, _): 28
        default: 18
        }
    }

    // MARK: - Content

    private func measure(_ entry: Entry, column: CGFloat) -> CGFloat {
        let row = entries.firstIndex { $0.id == entry.id } ?? 0
        return EntryCell.height(
            entry: entry, body: body(for: entry, row: row),
            detail: expanded.contains(entry.id) ? detail(for: entry) : nil,
            images: images(for: entry), width: column
        )
    }

    /// The row's main text, rendered once per revision.
    private func body(for entry: Entry, row: Int) -> RenderedText {
        let revision = revisions[safe: row] ?? entry.revision
        let streaming = isRunning && row == entries.count - 1
        if let cached = bodies[entry.id], cached.revision == revision, !(cached.text.needsHighlight && !streaming) {
            return cached.text
        }
        var text: RenderedText
        switch entry.kind {
        case .assistant:
            text = MarkdownRenderer(root: session.project.url).render(entry.text)
        case .notice:
            text = MarkdownRenderer(root: session.project.url, color: .secondaryLabelColor, preserveLineBreaks: true).render(entry.text)
        case .user:
            text = RenderedText(string: MarkdownRenderer.plain(entry.text))
        case .command:
            text = RenderedText(string: Self.commandText(entry.text))
        case .error:
            text = RenderedText(string: MarkdownRenderer.plain(entry.text, color: .systemRed))
        case .thinking:
            text = RenderedText(string: NSAttributedString(string: "Thinking", attributes: [.font: Fonts.body, .foregroundColor: NSColor.secondaryLabelColor]))
        case .tool:
            text = .empty
        }
        if !text.codeBlocks.isEmpty, !streaming {
            text = colored(text, entryID: entry.id)
        } else {
            text.needsHighlight = !text.codeBlocks.isEmpty
        }
        bodies[entry.id] = (revision, text)
        return text
    }

    /// What a thinking or tool row shows when it's opened.
    private func detail(for entry: Entry) -> RenderedText {
        let revision = entry.revision
        if let cached = details[entry.id], cached.revision == revision, !cached.text.needsHighlight { return cached.text }
        var text: RenderedText
        switch entry.kind {
        case .thinking:
            text = RenderedText(string: MarkdownRenderer.plain(entry.text, color: .secondaryLabelColor))
        case .tool:
            guard let tool = entry.tool else { return .empty }
            var blocks: [(code: String, language: String?, color: NSColor)] = []
            if let command = tool.input?["command"]?.string {
                blocks.append((command, "bash", .labelColor))
            } else if let input = tool.input {
                blocks.append((input.pretty, "json", .labelColor))
            }
            if let result = tool.result, !result.isEmpty {
                blocks.append((String(result.prefix(20_000)), nil, tool.isError ? .systemRed : .labelColor))
            }
            text = MarkdownRenderer(root: session.project.url).code(blocks)
            text = colored(text, entryID: entry.id)
        default:
            text = .empty
        }
        details[entry.id] = (revision, text)
        return text
    }

    private func colored(_ text: RenderedText, entryID: String) -> RenderedText {
        let string = NSMutableAttributedString(attributedString: text.string)
        let missing = Highlighter.apply(to: string, spans: text.codeBlocks, dark: darkMode)
        var result = RenderedText(string: string, codeBlocks: text.codeBlocks)
        if !missing.isEmpty {
            result.needsHighlight = true
            Highlighter.request(missing, dark: darkMode) { [weak self] in self?.highlighted(entryID) }
        }
        return result
    }

    private func highlighted(_ id: String) {
        bodies[id] = nil
        details[id] = nil
        guard let row = entries.firstIndex(where: { $0.id == id }) else { return }
        refreshVisibleRow(row)
    }

    private func images(for entry: Entry) -> [NSImage] {
        guard !entry.images.isEmpty else { return [] }
        if let cached = images[entry.id], cached.count == entry.images.count { return cached }
        let decoded = entry.images.compactMap(NSImage.init(data:))
        images[entry.id] = decoded
        return decoded
    }

    private static func commandText(_ command: String) -> NSAttributedString {
        let name = String(command.prefix { !$0.isWhitespace })
        let result = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: NSColor.controlAccentColor,
        ])
        let args = command.dropFirst(name.count)
        if !args.isEmpty {
            result.append(MarkdownRenderer.plain(String(args)))
        }
        return result
    }

    // MARK: - Actions from cells

    func toggle(_ id: String) {
        guard let row = entries.firstIndex(where: { $0.id == id }) else { return }
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        refreshVisibleRow(row)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }
    }
}

final class TranscriptTableView: NSTableView {
    // Text views inside rows handle their own clicks; the table never takes focus from the composer.
    override var acceptsFirstResponder: Bool { false }
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }
}
