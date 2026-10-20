import AppKit
import UniformTypeIdentifiers

/// A session: the transcript filling the pane, with the queue and composer floating over its bottom.
final class SessionViewController: NSViewController {
    let store: Store
    let session: Session
    private(set) var composer: ComposerView!
    private var transcript: TranscriptView!
    private var bottom: NSStackView!

    init(store: Store, session: Session) {
        self.store = store
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let draft = store.draft(for: session.id)
        let root = DropView(draft: draft)
        transcript = TranscriptView(session: session)
        root.addSubview(transcript)
        transcript.pin(to: root)

        composer = ComposerView(store: store, draft: draft, session: session)
        composer.onSend = { [weak self] text, attachments in
            guard let self else { return }
            store.submit(text, attachments: attachments, in: session)
        }
        composer.onStop = { [weak self] in self?.session.stop() }
        let queue = QueueView(session: session, draft: draft)
        bottom = NSStackView(views: [queue, composer])
        bottom.orientation = .vertical
        bottom.spacing = 0
        bottom.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bottom)
        NSLayoutConstraint.activate([
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            queue.widthAnchor.constraint(equalTo: bottom.widthAnchor),
            composer.widthAnchor.constraint(equalTo: bottom.widthAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        store.loadCommands(for: session.project)
        Task { await session.loadIfNeeded() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The fade at the top of the composer may overlap the last lines; the inset stops above the glass.
        transcript.bottomInset = bottom.frame.height - 8
    }
}

/// Before the first prompt: a heading over the composer, with the project it will run in.
final class NewSessionViewController: NSViewController {
    let store: Store
    private(set) var composer: ComposerView!
    private let path = NSTextField.label(color: .secondaryLabelColor)
    private let notice = TextLayout.makeTextView()
    private let noticeScroll = NSScrollView()
    private let noticeBox = FillView()
    private var noticeHeight: NSLayoutConstraint!
    private var observer: Observer?

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let draft = store.draft(for: "new")
        let root = DropView(draft: draft)

        let title = NSTextField.label("What should we build?", font: .systemFont(ofSize: 26, weight: .semibold))
        path.alignment = .center
        path.lineBreakMode = .byTruncatingMiddle
        noticeBox.fill = .quinarySystemFill
        let document = FlippedView()
        document.addSubview(notice)
        noticeScroll.documentView = document
        noticeScroll.drawsBackground = false
        noticeScroll.hasVerticalScroller = true
        noticeScroll.autohidesScrollers = true
        noticeBox.addSubview(noticeScroll)
        noticeScroll.pin(to: noticeBox, insets: NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0))
        noticeBox.translatesAutoresizingMaskIntoConstraints = false
        noticeHeight = noticeBox.heightAnchor.constraint(equalToConstant: 0)
        let heading = NSStackView(views: [title, path, noticeBox])
        heading.orientation = .vertical
        heading.spacing = 6
        heading.setCustomSpacing(18, after: path)
        heading.translatesAutoresizingMaskIntoConstraints = false

        composer = ComposerView(store: store, draft: draft, session: nil)
        composer.onSend = { [weak self] text, attachments in self?.store.submit(text, attachments: attachments, in: nil) }
        composer.translatesAutoresizingMaskIntoConstraints = false

        let area = NSLayoutGuide()
        root.addLayoutGuide(area)
        root.addSubview(heading)
        root.addSubview(composer)
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            area.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            area.bottomAnchor.constraint(equalTo: composer.topAnchor),
            heading.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            heading.centerYAnchor.constraint(equalTo: area.centerYAnchor),
            heading.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -48),
            noticeBox.widthAnchor.constraint(equalToConstant: 600),
            heading.topAnchor.constraint(greaterThanOrEqualTo: area.topAnchor, constant: 20),
            noticeHeight,
        ])
        view = root
        observer = Observer { [weak self] in self?.sync() }
    }

    private func sync() {
        path.stringValue = store.draftProject.map { $0.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? ""
        path.isHidden = store.draftProject == nil
        store.loadCommands(for: store.draftProject)
        // Replies to commands run here (/help, /model…) show under the heading.
        if let text = store.newSessionNotice {
            let rendered = MarkdownRenderer(root: store.draftProject?.url, color: .secondaryLabelColor, preserveLineBreaks: true).render(text)
            let size = TextLayout.size(of: rendered.string, width: 572)
            notice.frame.origin = NSPoint(x: 14, y: 8)
            notice.show(rendered.string, width: 572, height: size.height)
            noticeScroll.documentView?.frame = NSRect(x: 0, y: 0, width: 600, height: size.height + 16)
            noticeScroll.documentView?.scroll(.zero)
            noticeHeight.constant = min(size.height + 24, 340)
            noticeBox.isHidden = false
        } else {
            noticeBox.isHidden = true
        }
    }
}

/// Follow-ups waiting for the current turn to end: edit, send now, or drop each one.
final class QueueView: NSStackView {
    private let session: Session
    private let draft: Draft
    private var observer: Observer?

    init(session: Session, draft: Draft) {
        self.session = session
        self.draft = draft
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 0, right: 0)
        observer = Observer { [weak self] in self?.sync() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.textBackgroundColor.cgColor }

    private func sync() {
        let queue = session.queue
        let paused = session.isQueuePaused
        isHidden = queue.isEmpty
        guard !queue.isEmpty else {
            setViews([], in: .leading)
            return
        }
        let label = NSTextField.label(paused ? "Queue paused" : "Queued", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        let icon = NSImageView(image: .symbol("text.line.last.and.arrowtriangle.forward", size: 11))
        icon.contentTintColor = .secondaryLabelColor
        var header: [NSView] = [icon, label, NSView()]
        if paused {
            let resume = NSButton(title: "Resume", target: self, action: #selector(resumeQueue))
            resume.isBordered = false
            resume.font = .systemFont(ofSize: 11, weight: .medium)
            resume.contentTintColor = .controlAccentColor
            header.append(resume)
        }
        let headerRow = NSStackView(views: header)
        headerRow.spacing = 6
        let rows = queue.map { message in row(for: message) }
        let views = [headerRow] + rows
        setViews(views.map(column), in: .leading)
        for view in views { view.superview?.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
    }

    @objc private func resumeQueue() { session.resumeQueue() }

    /// Centers a row in the reading column, like the composer.
    private func column(_ view: NSView) -> NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(view)
        let fill = view.widthAnchor.constraint(equalTo: wrapper.widthAnchor, constant: -TranscriptView.margin * 2 - 20)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            view.widthAnchor.constraint(lessThanOrEqualToConstant: TranscriptView.maxColumnWidth - 20),
            fill,
            view.topAnchor.constraint(equalTo: wrapper.topAnchor),
            view.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        return wrapper
    }

    private func row(for message: QueuedMessage) -> NSView {
        let text = message.text.isEmpty ? message.attachments.map(\.name).joined(separator: ", ") : message.text
        let label = NSTextField.label(text.replacingOccurrences(of: "\n", with: " "))
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = []
        if !message.attachments.isEmpty {
            let clip = NSImageView(image: .symbol("paperclip", size: 12))
            clip.contentTintColor = .secondaryLabelColor
            views.append(clip)
        }
        views.append(label)
        views.append(NSView())
        let buttons = [
            ActionButton(symbol: "pencil", label: "Edit") { [weak self] in self?.edit(message) },
            ActionButton(symbol: "arrow.up.circle", label: "Send Now") { [weak self] in self?.session.sendNow(message) },
            ActionButton(symbol: "xmark", label: "Remove") { [weak self] in self?.session.queue.removeAll { $0.id == message.id } },
        ]
        for button in buttons { button.contentTintColor = .secondaryLabelColor }
        let row = NSStackView(views: views + buttons)
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        let background = FillView()
        background.fill = .quinarySystemFill
        background.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(background, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            background.topAnchor.constraint(equalTo: row.topAnchor),
            background.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    /// Pulls a queued message back into the composer, keeping whatever is already typed.
    private func edit(_ message: QueuedMessage) {
        session.queue.removeAll { $0.id == message.id }
        draft.text = [message.text, draft.text].filter { !$0.isEmpty }.joined(separator: "\n")
        draft.attachments = message.attachments + draft.attachments
    }
}

/// Lets a whole pane accept dropped files and images, with a quiet highlight while dragging.
final class DropView: NSView {
    private let draft: Draft
    private let overlay = DropOverlay()

    init(draft: Draft) {
        self.draft = draft
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType(UTType.image.identifier)])
        overlay.isHidden = true
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        overlay.frame = bounds.insetBy(dx: 12, dy: 12)
    }

    func setTargeted(_ targeted: Bool) {
        overlay.isHidden = !targeted
        if targeted { addSubview(overlay) }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        setTargeted(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { setTargeted(false) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { setTargeted(false) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        setTargeted(false)
        return draft.drop(from: sender.draggingPasteboard)
    }
}

private final class DropOverlay: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 16, yRadius: 16)
        NSColor.controlAccentColor.withAlphaComponent(0.06).setFill()
        path.fill()
        path.lineWidth = 2
        path.setLineDash([8, 6], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
        let text = NSAttributedString(string: "Drop to Attach", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.controlAccentColor,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
