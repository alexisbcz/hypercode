import AppKit

/// One transcript row, laid out by hand. `geometry` is shared by measuring and layout, so they always agree.
final class EntryCell: FlippedView {
    static func identifier(for kind: Entry.Kind) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("entry-\(kind)")
    }

    weak var transcript: TranscriptView?

    private var entry = Entry(id: "", kind: .assistant)
    private var top: CGFloat = 0
    private var body = RenderedText.empty
    private var detail: RenderedText?
    private var images: [NSImage] = []

    private let textView = TranscriptTextView.make()
    private lazy var detailView = TranscriptTextView.make()
    private lazy var background = FillView()
    private lazy var icon = NSImageView()
    private lazy var chevron = NSImageView()
    private lazy var headerLabel = NSTextField.label()
    private lazy var spinner = NSProgressIndicator()
    private lazy var statusIcon = NSImageView()
    private var imageViews: [NSImageView] = []
    private var chipViews: [FileChip] = []
    private var copyButtons: [CopyButton] = []

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(entry: Entry, top: CGFloat, body: RenderedText, detail: RenderedText?, images: [NSImage], isExpanded: Bool, root: URL) {
        self.entry = entry
        self.top = top
        self.body = body
        self.detail = detail
        self.images = images
        textView.root = root

        switch entry.kind {
        case .user, .command:
            install(background)
            background.fill = .quaternarySystemFill
            background.radius = 16
            syncImages()
            syncChips()
        case .notice:
            install(background)
            background.fill = .quinarySystemFill
            background.radius = 10
        case .error:
            install(icon)
            icon.image = .symbol("exclamationmark.triangle.fill", size: 13)
            icon.contentTintColor = .systemRed
        case .thinking, .tool:
            install(chevron)
            chevron.image = .symbol(isExpanded ? "chevron.down" : "chevron.right", size: 9, weight: .semibold)
            chevron.contentTintColor = .tertiaryLabelColor
            install(headerLabel)
            headerLabel.attributedStringValue = header()
            if entry.kind == .tool, let tool = entry.tool {
                install(icon)
                icon.image = .symbol(tool.symbol, size: 12)
                icon.contentTintColor = .secondaryLabelColor
                install(spinner)
                spinner.style = .spinning
                spinner.controlSize = .mini
                spinner.isHidden = tool.result != nil
                if tool.result == nil { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
                install(statusIcon)
                statusIcon.image = .symbol("xmark.circle.fill", size: 12)
                statusIcon.contentTintColor = .systemRed
                statusIcon.isHidden = !tool.isError
            }
            if detail != nil {
                install(detailView)
                detailView.root = root
            }
            detailView.isHidden = detail == nil
        case .assistant:
            break
        }
        textView.isHidden = entry.kind == .tool || entry.kind == .thinking
        syncCopyButtons()
        needsLayout = true
    }

    private func install(_ view: NSView) {
        if view.superview !== self { addSubview(view, positioned: view === background ? .below : .above, relativeTo: nil) }
    }

    // MARK: - Geometry

    struct Geometry {
        var height: CGFloat = 0
        var text = NSRect.zero
        var background: NSRect?
        var icon: NSRect?
        var header: NSRect?
        var detail: NSRect?
        var images: [NSRect] = []
        var chips: [NSRect] = []
    }

    static func height(entry: Entry, body: RenderedText, detail: RenderedText?, images: [NSImage], width: CGFloat) -> CGFloat {
        geometry(kind: entry.kind, body: body, detail: detail, images: images, files: entry.files, width: width).height
    }

    /// Frames relative to the top-left of the reading column.
    static func geometry(kind: Entry.Kind, body: RenderedText, detail: RenderedText?, images: [NSImage], files: [String], width: CGFloat) -> Geometry {
        var g = Geometry()
        switch kind {
        case .assistant:
            let size = TextLayout.size(of: body.string, width: width)
            g.text = NSRect(x: 0, y: 0, width: width, height: size.height)
            g.height = size.height
        case .notice:
            let size = TextLayout.size(of: body.string, width: width - 28)
            g.background = NSRect(x: 0, y: 0, width: width, height: size.height + 20)
            g.text = NSRect(x: 14, y: 10, width: width - 28, height: size.height)
            g.height = size.height + 20
        case .error:
            let size = TextLayout.size(of: body.string, width: width - 22)
            g.icon = NSRect(x: 0, y: 1, width: 16, height: 16)
            g.text = NSRect(x: 22, y: 0, width: width - 22, height: size.height)
            g.height = max(18, size.height)
        case .user, .command:
            var y: CGFloat = 0
            if !images.isEmpty {
                let sizes = images.map { image -> NSSize in
                    let s = image.size
                    guard s.width > 0, s.height > 0 else { return NSSize(width: 120, height: 120) }
                    let scale = min(240 / s.width, 180 / s.height, 1)
                    return NSSize(width: max(24, round(s.width * scale)), height: max(24, round(s.height * scale)))
                }
                var x = width - sizes.reduce(0) { $0 + $1.width } - CGFloat(sizes.count - 1) * 8
                let rowHeight = sizes.map(\.height).max() ?? 0
                for size in sizes {
                    g.images.append(NSRect(x: x, y: y + rowHeight - size.height, width: size.width, height: size.height))
                    x += size.width + 8
                }
                y += rowHeight + 8
            }
            if !files.isEmpty {
                let widths = files.map { min(220, FileChip.width(for: $0)) }
                var x = width - widths.reduce(0, +) - CGFloat(widths.count - 1) * 6
                for w in widths {
                    g.chips.append(NSRect(x: x, y: y, width: w, height: FileChip.height))
                    x += w + 6
                }
                y += FileChip.height + 8
            }
            if body.string.length > 0 {
                let size = TextLayout.size(of: body.string, width: width - 80 - 28)
                let bubble = NSRect(x: width - size.width - 28, y: y, width: size.width + 28, height: size.height + 20)
                g.background = bubble
                g.text = NSRect(x: bubble.minX + 14, y: bubble.minY + 10, width: size.width, height: size.height)
                y = bubble.maxY + 8
            }
            g.height = max(0, y - 8)
        case .thinking, .tool:
            g.header = NSRect(x: 0, y: 0, width: width, height: 20)
            g.height = 20
            if let detail {
                let size = TextLayout.size(of: detail.string, width: width - 18)
                g.detail = NSRect(x: 18, y: 26, width: width - 18, height: size.height)
                g.height = 26 + size.height
            }
        }
        return g
    }

    override func layout() {
        super.layout()
        let column = TranscriptView.column(for: bounds.width)
        let g = Self.geometry(kind: entry.kind, body: body, detail: detail, images: images, files: entry.files, width: column.width)
        let origin = NSPoint(x: column.x, y: top)
        func place(_ rect: NSRect) -> NSRect { rect.offsetBy(dx: origin.x, dy: origin.y) }

        if !textView.isHidden {
            textView.frame.origin = place(g.text).origin
            textView.show(body.string, width: g.text.width, height: g.text.height)
        }
        if let rect = g.background { background.frame = place(rect) }
        background.isHidden = g.background == nil
        if let rect = g.icon { icon.frame = place(rect) }

        if let header = g.header.map(place) {
            chevron.frame = NSRect(x: header.minX, y: header.minY + 5, width: 10, height: 10)
            var x = header.minX + 18
            if entry.kind == .tool {
                icon.frame = NSRect(x: x, y: header.minY + 2, width: 16, height: 16)
                x += 22
            }
            let trailing: CGFloat = entry.kind == .tool ? 22 : 0
            let labelWidth = min(header.maxX - trailing - x, ceil(headerLabel.cell?.cellSize.width ?? 0))
            headerLabel.frame = NSRect(x: x, y: header.minY + 1, width: max(0, labelWidth), height: 18)
            spinner.frame = NSRect(x: headerLabel.frame.maxX + 6, y: header.minY + 2, width: 16, height: 16)
            statusIcon.frame = spinner.frame
        }
        if let rect = g.detail, let detail {
            detailView.frame.origin = place(rect).origin
            detailView.show(detail.string, width: rect.width, height: rect.height)
        }
        for (view, rect) in zip(imageViews, g.images) { view.frame = place(rect) }
        for (view, rect) in zip(chipViews, g.chips) { view.frame = place(rect) }
        layoutCopyButtons(textOrigin: place(g.text).origin, width: g.text.width)
    }

    // MARK: - Pieces

    private func header() -> NSAttributedString {
        guard entry.kind == .tool, let tool = entry.tool else {
            return NSAttributedString(string: "Thinking", attributes: [.font: Fonts.body, .foregroundColor: NSColor.secondaryLabelColor])
        }
        let result = NSMutableAttributedString(string: tool.title, attributes: [.font: Fonts.body, .foregroundColor: NSColor.secondaryLabelColor])
        let summary = tool.summary.replacingOccurrences(of: "\n", with: " ")
        if !summary.isEmpty {
            result.append(NSAttributedString(string: "  " + summary.prefix(400), attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        return result
    }

    private func syncImages() {
        while imageViews.count > images.count { imageViews.removeLast().removeFromSuperview() }
        while imageViews.count < images.count {
            let view = ClickableImageView()
            view.imageScaling = .scaleProportionallyUpOrDown
            view.wantsLayer = true
            view.layer?.cornerRadius = 12
            view.layer?.masksToBounds = true
            view.toolTip = "Open in Preview"
            addSubview(view)
            imageViews.append(view)
        }
        for (i, view) in imageViews.enumerated() {
            view.image = images[i]
            (view as? ClickableImageView)?.data = entry.images[safe: i]
        }
    }

    private func syncChips() {
        while chipViews.count > entry.files.count { chipViews.removeLast().removeFromSuperview() }
        while chipViews.count < entry.files.count {
            let chip = FileChip()
            addSubview(chip)
            chipViews.append(chip)
        }
        for (chip, name) in zip(chipViews, entry.files) { chip.name = name }
    }

    /// A copy button in the corner of each code block of a reply.
    private func syncCopyButtons() {
        let spans = entry.kind == .assistant ? body.codeBlocks : []
        while copyButtons.count > spans.count { copyButtons.removeLast().removeFromSuperview() }
        while copyButtons.count < spans.count {
            let button = CopyButton()
            addSubview(button)
            copyButtons.append(button)
        }
        for (button, span) in zip(copyButtons, spans) { button.code = span.code }
    }

    private func layoutCopyButtons(textOrigin: NSPoint, width: CGFloat) {
        guard !copyButtons.isEmpty, let manager = textView.layoutManager, let container = textView.textContainer else { return }
        for (button, span) in zip(copyButtons, body.codeBlocks) {
            let glyphs = manager.glyphRange(forCharacterRange: span.range, actualCharacterRange: nil)
            let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            button.frame = NSRect(x: textOrigin.x + width - 26, y: textOrigin.y + rect.minY - 6, width: 22, height: 20)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The whole header line toggles the row, label included.
        if entry.kind == .tool || entry.kind == .thinking, let superview {
            let local = convert(point, from: superview)
            let column = TranscriptView.column(for: bounds.width)
            if local.y >= top, local.y < top + 20, local.x >= column.x, local.x < column.x + column.width { return self }
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if (entry.kind == .tool || entry.kind == .thinking), point.y >= top, point.y < top + 20 {
            transcript?.toggle(entry.id)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resetCursorRects() {
        if entry.kind == .tool || entry.kind == .thinking {
            let column = TranscriptView.column(for: bounds.width)
            addCursorRect(NSRect(x: column.x, y: top, width: column.width, height: 20), cursor: .pointingHand)
        }
    }
}

extension TranscriptTextView {
    static func make() -> TranscriptTextView { TextLayout.makeTextView() }
}

/// The working indicator under the last entry, with what the CLI is doing when it says.
final class ActivityCell: FlippedView {
    static let identifier = NSUserInterfaceItemIdentifier("activity")
    static let height: CGFloat = 36

    private let spinner = NSProgressIndicator()
    private let label = NSTextField.label(color: .secondaryLabelColor)

    var status: String? {
        didSet { label.stringValue = status ?? "" }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        addSubview(spinner)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let column = TranscriptView.column(for: bounds.width)
        spinner.frame = NSRect(x: column.x, y: 18, width: 16, height: 16)
        label.frame = NSRect(x: column.x + 24, y: 17, width: column.width - 24, height: 18)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { spinner.startAnimation(nil) }
    }
}

/// A rounded fill drawn with a dynamic color, so it follows light and dark mode without help.
final class FillView: NSView {
    var fill: NSColor = .quaternarySystemFill { didSet { needsDisplay = true } }
    var radius: CGFloat = 10 { didSet { needsDisplay = true } }
    var stroke: NSColor?

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        if let stroke {
            stroke.setStroke()
            let inner = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
            inner.lineWidth = 1
            inner.stroke()
        }
    }

    // Selecting text inside a bubble shouldn't be blocked by the bubble.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A sent file, by name.
final class FileChip: NSView {
    static let height: CGFloat = 26
    private static let font = NSFont.systemFont(ofSize: 12)

    static func width(for name: String) -> CGFloat {
        ceil((name as NSString).size(withAttributes: [.font: font]).width) + 40
    }

    private let icon = NSImageView(image: .symbol("doc", size: 11))
    private let label = NSTextField.label(font: FileChip.font)
    var name = "" { didSet { label.stringValue = name } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        icon.contentTintColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quinarySystemFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: (bounds.height - 14) / 2, width: 14, height: 14)
        label.frame = NSRect(x: 28, y: (bounds.height - 16) / 2, width: bounds.width - 38, height: 16)
    }
}

/// A sent image; click to open it full size in Preview.
final class ClickableImageView: NSImageView {
    var data: Data?

    override func mouseDown(with event: NSEvent) {
        guard let data else { return }
        let ext = data.starts(with: [0x89, 0x50]) ? "png" : "jpg"
        let url = FileManager.default.temporaryDirectory.appending(path: "hypercode-\(abs(data.hashValue)).\(ext)")
        try? data.write(to: url)
        NSWorkspace.shared.open(url)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Copies a code block, and says so for a moment.
final class CopyButton: NSButton {
    var code = ""

    init() {
        super.init(frame: .zero)
        isBordered = false
        image = .symbol("doc.on.doc", size: 11)
        contentTintColor = .tertiaryLabelColor
        toolTip = "Copy"
        target = self
        action = #selector(copyCode)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func copyCode() {
        copyToPasteboard(code)
        image = .symbol("checkmark", size: 11)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.image = .symbol("doc.on.doc", size: 11)
        }
    }
}
