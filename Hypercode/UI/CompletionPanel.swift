import AppKit

/// The slash-command list that floats above the composer: a borderless child window, so it can
/// overhang the transcript and take clicks while typing stays in the composer.
final class CompletionPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Item {
        var title: String
        var hint: String
        var detail: String
        var badge: String?
        /// What the composer holds once this is picked.
        var insert: String
        /// Return runs it right away (nothing left to type); Tab only completes.
        var runs: Bool
    }

    static let rowHeight: CGFloat = 30
    static let maxRows = 9

    var onPick: (Item, _ viaReturn: Bool) -> Void = { _, _ in }
    private(set) var items: [Item] = []

    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        let glass = NSGlassEffectView()
        glass.cornerRadius = 14
        glass.contentView = scrollView
        panel.contentView = glass
        return panel
    }()

    private lazy var tableView: NSTableView = {
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        return table
    }()

    private lazy var scrollView: NSScrollView = {
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        return scroll
    }()

    var isVisible: Bool { panel.isVisible }

    func show(_ items: [Item], above anchor: NSView) {
        guard let window = anchor.window else { return }
        // Same list (the caret moved): keep the highlight. New query: the best match is first.
        let previous = items.map(\.title) == self.items.map(\.title) ? tableView.selectedRow : 0
        self.items = items
        tableView.reloadData()
        select(max(0, previous))

        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let height = CGFloat(min(items.count, Self.maxRows)) * Self.rowHeight + 12
        panel.setFrame(NSRect(x: rect.minX, y: rect.maxY + 6, width: rect.width, height: height), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        items = []
        tableView.reloadData()
    }

    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        select((tableView.selectedRow + delta + items.count) % items.count)
    }

    func pickSelected(viaReturn: Bool) {
        guard let item = items[safe: tableView.selectedRow] else { return }
        onPick(item, viaReturn)
    }

    private func select(_ row: Int) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    @objc private func clicked() {
        guard tableView.clickedRow >= 0 else { return }
        select(tableView.clickedRow)
        pickSelected(viaReturn: true)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CompletionRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: CompletionCell.identifier, owner: nil) as? CompletionCell ?? CompletionCell()
        cell.item = items[safe: row]
        return cell
    }
}

private final class CompletionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 8, yRadius: 8).fill()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

private final class CompletionCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("completion")

    private let title = NSTextField.label(font: .monospacedSystemFont(ofSize: 12.5, weight: .medium))
    private let detail = NSTextField.label(font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private let badge = NSTextField.label(font: .systemFont(ofSize: 10.5, weight: .medium), color: .tertiaryLabelColor)

    var item: CompletionPanel.Item? {
        didSet {
            guard let item else { return }
            let text = NSMutableAttributedString(string: item.title, attributes: [.foregroundColor: NSColor.labelColor])
            if !item.hint.isEmpty {
                text.append(NSAttributedString(string: " " + item.hint, attributes: [
                    .foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
                ]))
            }
            title.attributedStringValue = text
            detail.stringValue = item.detail
            badge.stringValue = item.badge ?? ""
            badge.isHidden = item.badge == nil
            needsLayout = true
        }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        for label in [title, detail, badge] { addSubview(label) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let y = (bounds.height - 17) / 2
        let badgeWidth = badge.isHidden ? 0 : ceil(badge.cell?.cellSize.width ?? 0)
        let titleWidth = min(ceil(title.cell?.cellSize.width ?? 0), bounds.width * 0.55)
        title.frame = NSRect(x: 16, y: y, width: titleWidth, height: 17)
        badge.frame = NSRect(x: bounds.width - 16 - badgeWidth, y: y + 1, width: badgeWidth, height: 15)
        let detailX = title.frame.maxX + 12
        detail.frame = NSRect(x: detailX, y: y, width: max(0, badge.frame.minX - 10 - detailX), height: 17)
    }
}
