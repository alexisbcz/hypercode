import AppKit
import UniformTypeIdentifiers

/// The prompt box: a growing text view in a glass capsule, attachments above it, and the
/// project / permission / model / effort menus below. Typing "/" opens the command list.
final class ComposerView: NSView, NSTextViewDelegate {
    static let buttonSize: CGFloat = 28

    let store: Store
    let draft: Draft
    weak var session: Session?
    var onSend: (String, [Attachment]) -> Void = { _, _ in }
    var onStop: () -> Void = {}

    private let column = NSView()
    private let fade = FadeView()
    private let glass = NSGlassEffectView()
    private let textView = ComposerTextView(usingTextLayoutManager: false)
    private let textScroll = NSScrollView()
    private var textHeight: NSLayoutConstraint!
    private lazy var attachButton = NSButton.icon("plus", size: 17, weight: .medium, label: "Attach Files", target: self, action: #selector(chooseFiles))
    private lazy var stopButton = NSButton.icon("stop.circle.fill", size: 22, label: "Stop", target: self, action: #selector(stop))
    private lazy var sendButton = NSButton.icon("arrow.up.circle.fill", size: 22, label: "Send", target: self, action: #selector(send))
    private let strip = AttachmentStrip()
    private let projectButton = MenuButton()
    private let modeButton = MenuButton()
    private let modelButton = MenuButton()
    private let effortButton = MenuButton()
    private let contextLabel = NSButton(title: "", target: nil, action: nil)
    private let completions = CompletionPanel()
    private var observers: [Observer] = []

    private var isRunning: Bool { session?.isRunning ?? false }
    private var project: Project? { session?.project ?? store.draftProject }

    init(store: Store, draft: Draft, session: Session?) {
        self.store = store
        self.draft = draft
        self.session = session
        super.init(frame: .zero)
        build()
        completions.onPick = { [weak self] item, viaReturn in self?.pick(item, viaReturn: viaReturn) }
        observers.append(Observer { [weak self] in self?.syncDraft() })
        observers.append(Observer { [weak self] in self?.syncState() })
        observers.append(Observer { [weak self] in self?.syncMenus() })
        observers.append(Observer { [weak self] in self?.syncContext() })
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Building

    private func build() {
        addSubview(fade)
        fade.pin(to: self)

        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        let fill = column.widthAnchor.constraint(equalTo: widthAnchor, constant: -TranscriptView.margin * 2)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: TranscriptView.maxColumnWidth),
            fill,
            column.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])

        // Text
        textView.delegate = self
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // Files and images dropped on the field attach, like anywhere else in the pane; text drags still insert.
        textView.registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType(UTType.image.identifier)])
        textView.onPaste = { [weak self] in self?.draft.paste(from: .general) ?? false }
        textView.onDrop = { [weak self] in self?.draft.drop(from: $0) ?? false }
        textScroll.documentView = textView
        textScroll.drawsBackground = false
        textScroll.hasVerticalScroller = false
        textScroll.verticalScrollElasticity = .none
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textHeight = textScroll.heightAnchor.constraint(equalToConstant: Self.buttonSize)
        textHeight.isActive = true
        // Sets the inset that centers a single line on the buttons, so the placeholder lines up from the start.
        updateHeight()

        for button in [attachButton, stopButton, sendButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: Self.buttonSize),
                button.heightAnchor.constraint(equalToConstant: Self.buttonSize),
            ])
        }
        attachButton.toolTip = "Attach images or files (you can also drop or paste them)"
        attachButton.contentTintColor = .secondaryLabelColor
        sendButton.contentTintColor = .controlAccentColor
        stopButton.contentTintColor = .labelColor

        let input = NSStackView(views: [attachButton, textScroll, stopButton, sendButton])
        input.orientation = .horizontal
        input.alignment = .bottom
        input.spacing = 8

        let inner = NSStackView(views: [strip, input])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 10
        inner.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        input.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -20).isActive = true
        strip.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -20).isActive = true
        strip.draft = draft

        glass.cornerRadius = 20
        glass.contentView = inner
        glass.translatesAutoresizingMaskIntoConstraints = false

        // Footer
        projectButton.symbol = "folder"
        modeButton.symbol = "hand.raised"
        modelButton.symbol = "cpu"
        effortButton.symbol = "gauge.with.dots.needle.50percent"
        projectButton.makeMenu = { [weak self] in self?.projectMenu() ?? NSMenu() }
        modeButton.makeMenu = { [weak self] in self?.modeMenu() ?? NSMenu() }
        modelButton.makeMenu = { [weak self] in self?.modelMenu() ?? NSMenu() }
        effortButton.makeMenu = { [weak self] in self?.effortMenu() ?? NSMenu() }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        // Looks like the menus beside it, but only informs.
        contextLabel.isBordered = false
        contextLabel.image = .symbol("chart.pie", size: 12)
        contextLabel.imagePosition = .imageLeading
        contextLabel.imageHugsTitle = true
        contextLabel.font = .systemFont(ofSize: 12.5)
        contextLabel.contentTintColor = .secondaryLabelColor
        contextLabel.isHidden = true
        let footer = NSStackView(views: [projectButton, modeButton, spacer, contextLabel, modelButton, effortButton])
        footer.orientation = .horizontal
        footer.spacing = 16
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        footer.translatesAutoresizingMaskIntoConstraints = false

        column.addSubview(glass)
        column.addSubview(footer)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: column.topAnchor),
            glass.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            footer.topAnchor.constraint(equalTo: glass.bottomAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    /// Starts a command from the menu (⌘/): a "/" ready for the name, with the list open.
    func beginCommand() {
        if !textView.string.hasPrefix("/") {
            textView.string = "/" + textView.string
            textDidChange(Notification(name: NSText.didChangeNotification))
        }
        focus()
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        updateCompletions()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            DispatchQueue.main.async { [weak self] in self?.focus() }
        } else {
            completions.hide()
        }
    }

    // MARK: - State

    private func syncDraft() {
        let text = draft.text
        if text != textView.string {
            textView.string = text
            updateHeight()
        }
        strip.attachments = draft.attachments
        strip.isHidden = draft.attachments.isEmpty
        updateButtons()
    }

    private func syncState() {
        _ = session?.isRunning
        textView.placeholder = isRunning ? "Queue a follow-up…" : "Ask Claude to build, fix, or explain…"
        textView.needsDisplay = true
        updateButtons()
    }

    private func updateButtons() {
        let running = isRunning, empty = draft.isEmpty
        stopButton.isHidden = !running
        sendButton.isHidden = running && empty
        sendButton.isEnabled = !empty
        sendButton.image = .symbol(running ? "text.line.last.and.arrowtriangle.forward" : "arrow.up.circle.fill", size: running ? 17 : 22)
        sendButton.toolTip = running ? "Queue — sent when Claude finishes this turn" : "Send"
        sendButton.contentTintColor = running ? .labelColor : .controlAccentColor
    }

    private func syncMenus() {
        projectButton.isHidden = session != nil
        projectButton.title = store.draftProject?.name ?? "Choose Project"
        modeButton.title = store.config.mode.label
        modelButton.title = store.model.shortLabel
        effortButton.title = store.config.effort?.label ?? ""
        effortButton.isHidden = store.config.effort == nil || store.efforts.isEmpty
        let enabled = project != nil
        textView.isEditable = enabled
        attachButton.isEnabled = enabled
        // The command list depends on the project, and may arrive while it's open.
        _ = store.commands(for: project)
        if completions.isVisible { updateCompletions() }
    }

    /// "42K / 1M": how much of the context window the conversation fills.
    private func syncContext() {
        guard let tokens = session?.contextTokens else {
            contextLabel.isHidden = true
            return
        }
        let compact = { (n: Int) in n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
        contextLabel.isHidden = false
        if let window = session?.contextWindow, window > 0 {
            let percent = (Double(tokens) / Double(window)).formatted(.percent.precision(.fractionLength(0)))
            contextLabel.title = "\(compact(tokens)) / \(compact(window))"
            contextLabel.toolTip = "Context: \(tokens.formatted()) of \(window.formatted()) tokens (\(percent))"
        } else {
            contextLabel.title = "\(compact(tokens)) tokens"
            contextLabel.toolTip = "Context: \(tokens.formatted()) tokens"
        }
    }

    // MARK: - Sending

    @objc private func send() {
        guard !draft.isEmpty, project != nil else { return }
        completions.hide()
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = draft.attachments
        draft.clear()
        onSend(text, attachments)
    }

    @objc private func stop() { onStop() }

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.directoryURL = project?.url
        guard panel.runModal() == .OK else { return }
        draft.add(panel.urls)
        focus()
    }

    // MARK: - Text view

    func textDidChange(_ notification: Notification) {
        if draft.text != textView.string { draft.text = textView.string }
        updateHeight()
        updateCompletions()
        textView.needsDisplay = true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if completions.isVisible { updateCompletions() }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)):
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else if completions.isVisible {
                completions.pickSelected(viaReturn: true)
            } else {
                send()
            }
            return true
        case #selector(insertTab(_:)) where completions.isVisible:
            completions.pickSelected(viaReturn: false)
            return true
        case #selector(moveUp(_:)) where completions.isVisible:
            completions.move(by: -1)
            return true
        case #selector(moveDown(_:)) where completions.isVisible:
            completions.move(by: 1)
            return true
        case #selector(cancelOperation(_:)) where completions.isVisible:
            completions.hide()
            return true
        default:
            return false
        }
    }

    private func updateHeight() {
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
        manager.ensureLayout(for: container)
        let line = manager.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 15))
        let used = max(line, manager.usedRect(for: container).height)
        let maxHeight = line * 12
        // One line sits on the buttons' center line; more lines grow upward.
        let inset = max(0, (Self.buttonSize - line) / 2)
        textView.textContainerInset = NSSize(width: 0, height: inset)
        let height = min(maxHeight, used) + inset * 2
        textScroll.hasVerticalScroller = used > maxHeight
        if textHeight.constant != height { textHeight.constant = height }
    }

    // MARK: - Commands

    private func updateCompletions() {
        let text = textView.string
        let caret = textView.selectedRange().location
        guard text.hasPrefix("/"), !text.contains("\n"), caret <= (text as NSString).length,
              let items = suggestions(for: text), !items.isEmpty
        else {
            completions.hide()
            textView.hint = nil
            updateHint()
            return
        }
        completions.show(items, above: glass)
        updateHint()
    }

    private func updateHint() {
        let text = textView.string
        // "/compact " shows "<optional custom summarization instructions>" in gray after the caret.
        if text.hasPrefix("/"), text.hasSuffix(" "), text.filter({ $0 == " " }).count == 1 {
            let name = String(text.dropFirst().dropLast())
            textView.hint = store.commands(for: project).first { $0.matches(name) }?.argumentHint
        } else {
            textView.hint = nil
        }
        textView.needsDisplay = true
    }

    private func suggestions(for text: String) -> [CompletionPanel.Item]? {
        let body = text.dropFirst()
        if let space = body.firstIndex(of: " ") {
            // Arguments: models and effort levels are known, so they get their own list.
            let name = body[..<space].lowercased()
            let arg = body[body.index(after: space)...].lowercased()
            guard !arg.contains(" ") else { return nil }
            switch name {
            case "model":
                return store.models
                    .filter { arg.isEmpty || $0.value.lowercased().hasPrefix(arg) || $0.displayName.lowercased().contains(arg) }
                    .map { .init(title: $0.value, hint: $0.displayName, detail: $0.description, badge: $0.value == store.config.model ? "current" : nil, insert: "/model \($0.value)", runs: true) }
            case "effort":
                return store.efforts
                    .filter { arg.isEmpty || $0.rawValue.hasPrefix(arg) }
                    .map { .init(title: $0.rawValue, hint: "", detail: $0.label, badge: $0 == store.config.effort ? "current" : nil, insert: "/effort \($0.rawValue)", runs: true) }
            default:
                return nil
            }
        }
        let query = body.lowercased()
        let commands = store.commands(for: project)
        let ranked: [(Int, SlashCommand)] = commands.compactMap { command in
            let name = command.name.lowercased()
            if query.isEmpty { return (0, command) }
            if name.hasPrefix(query) { return (name == query ? 0 : 1, command) }
            if command.aliases.contains(where: { $0.hasPrefix(query) }) { return (2, command) }
            // "review" finds "code-review"; "pdf" finds "anthropic-skills:pdf".
            if name.split(whereSeparator: { $0 == "-" || $0 == ":" }).contains(where: { $0.hasPrefix(query) }) { return (3, command) }
            if name.contains(query) { return (4, command) }
            if command.description.lowercased().contains(query) { return (5, command) }
            return nil
        }
        return ranked.enumerated()
            .sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
            .map(\.element.1)
            .map { command in
                let aliases = command.aliases.isEmpty ? "" : "  (" + command.aliases.map { "/" + $0 }.joined(separator: ", ") + ")"
                return .init(
                    title: "/" + command.name, hint: command.argumentHint + aliases, detail: command.description,
                    badge: command.isBuiltin ? nil : "skill",
                    insert: "/" + command.name + (command.takesArguments ? " " : ""), runs: !command.takesArguments
                )
            }
    }

    private func pick(_ item: CompletionPanel.Item, viaReturn: Bool) {
        textView.string = item.insert
        draft.text = item.insert
        textView.setSelectedRange(NSRange(location: (item.insert as NSString).length, length: 0))
        updateHeight()
        if viaReturn && item.runs {
            completions.hide()
            send()
        } else {
            updateCompletions()
        }
    }

    // MARK: - Menus

    private func projectMenu() -> NSMenu {
        let menu = NSMenu()
        for project in store.projects {
            let item = MenuAction.item(project.name) { [weak self] in self?.store.draftProject = project }
            item.state = project == store.draftProject ? .on : .off
            menu.addItem(item)
        }
        if !store.projects.isEmpty { menu.addItem(.separator()) }
        menu.addItem(MenuAction.item("Open Project…") { [weak self] in self?.store.openProject() })
        return menu
    }

    private func modeMenu() -> NSMenu {
        let menu = NSMenu()
        for mode in PermissionMode.allCases {
            let item = MenuAction.item(mode.label) { [weak self] in self?.store.config.mode = mode }
            item.state = mode == store.config.mode ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// Every model `/model` lists, each with its description as a subtitle.
    private func modelMenu() -> NSMenu {
        let menu = NSMenu()
        for model in store.models {
            let item = MenuAction.item(model.displayName) { [weak self] in self?.store.selectModel(model.value) }
            if !model.description.isEmpty { item.subtitle = model.description }
            item.state = model.value == store.config.model ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func effortMenu() -> NSMenu {
        let menu = NSMenu()
        for effort in store.efforts {
            let item = MenuAction.item(effort.label) { [weak self] in self?.store.config.effort = effort }
            item.state = effort == store.config.effort ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}

// MARK: - Text view

/// Draws its placeholder and a command's argument hint, and hands pasted images and files to the draft.
final class ComposerTextView: NSTextView {
    var placeholder = ""
    var hint: String?
    var onPaste: () -> Bool = { false }
    var onDrop: (NSPasteboard) -> Bool = { _ in false }

    private var dropView: DropView? {
        sequence(first: superview, next: { $0?.superview }).compactMap { $0 as? DropView }.first
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard Draft.canDrop(sender.draggingPasteboard) else { return super.draggingEntered(sender) }
        dropView?.setTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Draft.canDrop(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropView?.setTargeted(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        Draft.canDrop(sender.draggingPasteboard) || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropView?.setTargeted(false)
        if Draft.canDrop(sender.draggingPasteboard), onDrop(sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    override func paste(_ sender: Any?) {
        if onPaste() { return }
        pasteAsPlainText(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 15), .foregroundColor: NSColor.placeholderTextColor]
        let origin = textContainerOrigin
        if string.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: origin.x, y: origin.y), withAttributes: attributes)
        } else if let hint, !hint.isEmpty, let manager = layoutManager, let container = textContainer {
            let glyphs = manager.glyphRange(for: container)
            let end = manager.boundingRect(forGlyphRange: NSRange(location: max(0, NSMaxRange(glyphs) - 1), length: 1), in: container)
            (hint as NSString).draw(at: NSPoint(x: origin.x + end.maxX + 2, y: origin.y + end.minY), withAttributes: attributes)
        }
    }
}

/// A quiet footer menu in the style of Claude Desktop: symbol and title, no chrome.
final class MenuButton: NSButton {
    var makeMenu: () -> NSMenu = { NSMenu() }
    var symbol = "" { didSet { image = .symbol(symbol, size: 12) } }

    init() {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageLeading
        imageHugsTitle = true
        font = .systemFont(ofSize: 12.5)
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(open)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func open() {
        makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}

/// Menu items that run a closure, so menus can be built inline.
final class MenuAction: NSObject {
    private let handler: () -> Void
    private init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc private func run() { handler() }

    static func item(_ title: String, key: String = "", _ handler: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: key)
        item.target = action
        item.representedObject = action
        return item
    }
}

/// Fades the transcript out beneath the composer.
final class FadeView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CAGradientLayer()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        guard let gradient = layer as? CAGradientLayer else { return }
        let color = NSColor.textBackgroundColor.cgColor
        gradient.colors = [color.copy(alpha: 0) ?? color, color]
        // Clear at the top edge, opaque from a third of the way down.
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.locations = [0, 0.35]
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Attachments

/// The composer's pending attachments: image thumbnails and file chips, each removable.
final class AttachmentStrip: NSScrollView {
    weak var draft: Draft?
    private let stack = NSStackView()

    var attachments: [Attachment] = [] {
        didSet {
            guard attachments.map(\.id) != oldValue.map(\.id) else { return }
            stack.setViews(attachments.map { attachment in
                AttachmentChip(attachment: attachment) { [weak self] in
                    self?.draft?.attachments.removeAll { $0.id == attachment.id }
                }
            }, in: .leading)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        documentView = document
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        verticalScrollElasticity = .none
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 62),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            document.heightAnchor.constraint(equalTo: contentView.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

private final class AttachmentChip: NSView {
    init(attachment: Attachment, onRemove: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let card = FillView()
        card.fill = .quinarySystemFill
        card.stroke = .separatorColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        if let data = attachment.imageData, let image = NSImage(data: data) {
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.wantsLayer = true
            view.layer?.cornerRadius = 10
            view.layer?.masksToBounds = true
            view.layer?.contentsGravity = .resizeAspectFill
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            toolTip = attachment.name
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: 56), view.heightAnchor.constraint(equalToConstant: 56),
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.topAnchor.constraint(equalTo: topAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        } else if case .file(let url) = attachment.kind {
            let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
            let label = NSTextField.label(attachment.name, font: .systemFont(ofSize: 12))
            label.lineBreakMode = .byTruncatingMiddle
            let row = NSStackView(views: [icon, label])
            row.spacing = 8
            row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            toolTip = url.path
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
                row.heightAnchor.constraint(equalToConstant: 56),
                row.leadingAnchor.constraint(equalTo: leadingAnchor), row.topAnchor.constraint(equalTo: topAnchor),
                row.trailingAnchor.constraint(equalTo: trailingAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        card.pin(to: self)

        let remove = ActionButton(symbol: "xmark.circle.fill", size: 14, label: "Remove", onRemove)
        remove.symbolConfiguration = .init(paletteColors: [.white, NSColor.black.withAlphaComponent(0.6)])
        remove.translatesAutoresizingMaskIntoConstraints = false
        addSubview(remove)
        NSLayoutConstraint.activate([
            remove.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            remove.centerYAnchor.constraint(equalTo: topAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
