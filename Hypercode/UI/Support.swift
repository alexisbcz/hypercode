import AppKit
import Observation

/// Runs `body` now and again whenever an `@Observable` property it read changes.
/// Changes made in the same main-queue turn (a burst of stream events) collapse into one run.
final class Observer {
    private let body: () -> Void
    private var isCancelled = false

    init(_ body: @escaping () -> Void) {
        self.body = body
        track()
    }

    private func track() {
        guard !isCancelled else { return }
        withObservationTracking(body, onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.track() } }
        })
    }

    func cancel() { isCancelled = true }
}

/// Measures attributed strings exactly as `TextLayout.makeTextView()` lays them out (TextKit 1, no insets),
/// so row heights can be computed without a view.
enum TextLayout {
    private static let storage = NSTextStorage()
    private static let container: NSTextContainer = {
        let container = NSTextContainer(size: .zero)
        container.lineFragmentPadding = 0
        return container
    }()
    private static let manager: NSLayoutManager = {
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        return manager
    }()

    static func size(of string: NSAttributedString, width: CGFloat) -> NSSize {
        guard string.length > 0, width > 0 else { return .zero }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        storage.setAttributedString(string)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return NSSize(width: ceil(used.width), height: ceil(used.height))
    }

    static func makeTextView() -> TranscriptTextView {
        let view = TranscriptTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        return view
    }
}

/// A read-only transcript text view that opens links the way the rest of the app does.
final class TranscriptTextView: NSTextView {
    var root: URL?

    func show(_ string: NSAttributedString, width: CGFloat, height: CGFloat) {
        textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        if textStorage?.isEqual(to: string) != true { textStorage?.setAttributedString(string) }
        setFrameSize(NSSize(width: width, height: height))
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        if let url { Links.open(url, root: root) }
    }

    // Scrolling belongs to the transcript, not each message.
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

extension NSImage {
    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, scale: NSImage.SymbolScale = .medium) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: size, weight: weight, scale: scale)) ?? image
    }
}

extension NSButton {
    /// A borderless symbol button, the AppKit twin of SwiftUI's `.borderless` icon buttons.
    static func icon(_ symbol: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, label: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(image: .symbol(symbol, size: size, weight: weight), target: target, action: action)
        button.isBordered = false
        button.setAccessibilityLabel(label)
        button.toolTip = label
        button.imageScaling = .scaleNone
        return button
    }
}

/// A borderless symbol button that runs a closure.
final class ActionButton: NSButton {
    var handler: () -> Void

    init(symbol: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, label: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        image = .symbol(symbol, size: size, weight: weight)
        isBordered = false
        imageScaling = .scaleNone
        toolTip = label
        setAccessibilityLabel(label)
        target = self
        action = #selector(run)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

extension NSTextField {
    static func label(_ text: String = "", font: NSFont = Fonts.body, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        return field
    }
}

extension NSView {
    func pin(to other: NSView, insets: NSEdgeInsets = .init()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
        ])
    }

    var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// A flipped plain view, for manual top-down layout.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
