import AppKit
import HighlightSwift
import Markdown

enum Fonts {
    static let bodySize: CGFloat = 13
    static let body = NSFont.systemFont(ofSize: bodySize)
    static let code = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let lineSpacing: CGFloat = 3
}

/// A rendered message, plus where its code blocks sit so they can be colored and copied.
struct RenderedText {
    var string: NSAttributedString
    var codeBlocks: [CodeSpan] = []
    /// Set while code blocks wait on highlight.js, or while the reply is still streaming.
    var needsHighlight = false

    static let empty = RenderedText(string: NSAttributedString())
}

struct CodeSpan {
    let range: NSRange
    let code: String
    let language: String?
}

/// GitHub-flavored Markdown → one TextKit 1 attributed string: code blocks and quotes are `NSTextBlock`s,
/// tables are `NSTextTable`s. One string per message means one text view per row, laid out once and cached.
struct MarkdownRenderer {
    var root: URL?
    var color: NSColor = .labelColor
    /// Command output is preformatted text that happens to use Markdown; its single newlines matter.
    var preserveLineBreaks = false

    func render(_ text: String) -> RenderedText {
        let builder = Builder(renderer: self)
        let document = Document(parsing: text, options: [.parseBlockDirectives])
        builder.blocks(Array(document.children), context: Context(color: color))
        return builder.finish()
    }

    /// Code alone, as a tool's input or output is shown.
    func code(_ blocks: [(code: String, language: String?, color: NSColor)]) -> RenderedText {
        let builder = Builder(renderer: self)
        for (i, block) in blocks.enumerated() {
            builder.codeBlock(block.code, language: block.language, context: Context(color: block.color), gap: i == 0 ? 0 : 8)
        }
        return builder.finish()
    }

    /// Plain text with links, in the transcript's body style.
    static func plain(_ text: String, color: NSColor = .labelColor, font: NSFont = Fonts.body) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = Fonts.lineSpacing
        return Links.linkified(text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    fileprivate struct Context {
        var color: NSColor
        var indent: CGFloat = 0
        var blocks: [NSTextBlock] = []
        var gap: CGFloat = 10
        /// A list marker waiting for the item's first paragraph.
        var marker: String?
        var markerWidth: CGFloat = 0
    }

    fileprivate struct Traits {
        var size = Fonts.bodySize
        var bold = false
        var italic = false
        var color: NSColor
    }

    fileprivate final class Builder {
        let renderer: MarkdownRenderer
        let output = NSMutableAttributedString()
        var codeBlocks: [CodeSpan] = []

        init(renderer: MarkdownRenderer) { self.renderer = renderer }

        func finish() -> RenderedText {
            if output.string.hasSuffix("\n") { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }
            return RenderedText(string: output, codeBlocks: codeBlocks)
        }

        func blocks(_ children: [any Markup], context: Context) {
            var context = context
            for (i, child) in children.enumerated() {
                block(child, context: context, gap: i == 0 && context.marker == nil ? context.gap : context.gap)
                context.marker = nil
            }
        }

        func block(_ markup: any Markup, context: Context, gap: CGFloat) {
            switch markup {
            case let paragraph as Paragraph:
                appendParagraph(inline(paragraph, Traits(color: context.color)), context: context, gap: gap)
            case let heading as Heading:
                let size: CGFloat = [20, 16, 14][safe: heading.level - 1] ?? 13
                let text = inline(heading, Traits(size: size, bold: true, color: context.color))
                appendParagraph(text, context: context, gap: heading.level <= 2 ? 18 : 14)
            case let code as CodeBlock:
                codeBlock(code.code.trimmingCharacters(in: .newlines), language: code.language, context: context, gap: gap)
            case let list as UnorderedList:
                listItems(Array(list.listItems), ordered: false, start: 1, context: context, gap: gap)
            case let list as OrderedList:
                listItems(Array(list.listItems), ordered: true, start: Int(list.startIndex), context: context, gap: gap)
            case let quote as BlockQuote:
                let bar = QuoteBlock()
                bar.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
                place(bar, context: context, gap: gap)
                var inner = context
                inner.indent = 0
                inner.blocks.append(bar)
                inner.color = .secondaryLabelColor
                inner.gap = 8
                // The first paragraph carries the gap before the quote.
                let children = Array(quote.children)
                for (i, child) in children.enumerated() { block(child, context: inner, gap: i == 0 ? 0 : 8) }
            case let table as Markdown.Table:
                self.table(table, context: context, gap: gap)
            case is ThematicBreak:
                let rule = RuleBlock()
                rule.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minY)
                rule.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxY)
                place(rule, context: context, gap: gap)
                var inner = context
                inner.indent = 0
                inner.blocks.append(rule)
                appendParagraph(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 2)]), context: inner, gap: 0)
            case let html as HTMLBlock:
                let text = NSAttributedString(string: html.rawHTML.trimmingCharacters(in: .newlines), attributes: [
                    .font: Fonts.code, .foregroundColor: NSColor.secondaryLabelColor,
                ])
                appendParagraph(text, context: context, gap: gap)
            default:
                blocks(Array(markup.children), context: context)
            }
        }

        // MARK: Paragraphs

        func paragraphStyle(_ context: Context, gap: CGFloat) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = Fonts.lineSpacing
            style.paragraphSpacingBefore = output.length == 0 ? 0 : gap
            style.headIndent = context.indent
            style.firstLineHeadIndent = context.indent
            style.textBlocks = context.blocks
            return style
        }

        func appendParagraph(_ text: NSAttributedString, context: Context, gap: CGFloat) {
            let style = paragraphStyle(context, gap: gap)
            let paragraph = NSMutableAttributedString()
            if let marker = context.marker {
                // Marker hangs in the gutter: "•<tab>text", with wrapped lines aligned to the text.
                style.firstLineHeadIndent = context.indent - context.markerWidth
                style.tabStops = [NSTextTab(textAlignment: .left, location: context.indent)]
                style.defaultTabInterval = context.markerWidth
                paragraph.append(NSAttributedString(string: marker + "\t", attributes: [
                    .font: Fonts.body.monospacedDigit, .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            paragraph.append(text)
            paragraph.append(NSAttributedString(string: "\n"))
            paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
            output.append(paragraph)
        }

        /// A block spans the column (less its indent), and its gap above is a margin so it sits outside the fill.
        func place(_ block: NSTextBlock, context: Context, gap: CGFloat) {
            block.setContentWidth(100, type: .percentageValueType)
            block.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
            block.setWidth(output.length == 0 ? 0 : gap, type: .absoluteValueType, for: .margin, edge: .minY)
        }

        func listItems(_ items: [ListItem], ordered: Bool, start: Int, context: Context, gap: CGFloat) {
            let widest = ordered ? "\(start + items.count - 1)." : "•"
            let markerWidth = max(16, ceil((widest as NSString).size(withAttributes: [.font: Fonts.body.monospacedDigit]).width) + 8)
            for (i, item) in items.enumerated() {
                var inner = context
                inner.indent = context.indent + markerWidth
                inner.markerWidth = markerWidth
                inner.gap = 4
                inner.marker = switch item.checkbox {
                case .checked: "☑"
                case .unchecked: "☐"
                case nil: ordered ? "\(start + i)." : "•"
                }
                let children = Array(item.children)
                for (j, child) in children.enumerated() {
                    block(child, context: inner, gap: i == 0 && j == 0 ? gap : 4)
                    inner.marker = nil
                }
            }
        }

        func codeBlock(_ code: String, language: String?, context: Context, gap: CGFloat) {
            let block = CodeBlockBackground()
            for edge in [NSRectEdge.minX, .maxX] { block.setWidth(12, type: .absoluteValueType, for: .padding, edge: edge) }
            for edge in [NSRectEdge.minY, .maxY] { block.setWidth(9, type: .absoluteValueType, for: .padding, edge: edge) }
            place(block, context: context, gap: gap)
            var inner = context
            inner.indent = 0
            inner.blocks.append(block)
            let style = paragraphStyle(inner, gap: 0)
            style.lineSpacing = 2
            style.lineBreakMode = .byCharWrapping
            let text = code.isEmpty ? " " : code
            let start = output.length
            output.append(NSAttributedString(string: text + "\n", attributes: [
                .font: Fonts.code, .foregroundColor: context.color, .paragraphStyle: style,
            ]))
            codeBlocks.append(CodeSpan(range: NSRange(location: start, length: (text as NSString).length), code: text, language: language))
        }

        func table(_ table: Markdown.Table, context: Context, gap: CGFloat) {
            let header = Array(table.head.cells)
            let rows = table.body.rows.map { Array($0.cells) }
            let columns = max(header.count, rows.map(\.count).max() ?? 0)
            guard columns > 0 else { return }
            let textTable = NSTextTable()
            textTable.numberOfColumns = columns
            textTable.collapsesBorders = true
            textTable.hidesEmptyCells = false
            textTable.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
            textTable.setWidth(gap, type: .absoluteValueType, for: .margin, edge: .minY)
            textTable.setWidth(0.5, type: .absoluteValueType, for: .border)
            textTable.setBorderColor(.separatorColor)

            let alignments = table.columnAlignments
            for (r, cells) in ([header] + rows).enumerated() {
                for column in 0..<columns {
                    let cell = NSTextTableBlock(table: textTable, startingRow: r, rowSpan: 1, startingColumn: column, columnSpan: 1)
                    cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                    cell.setBorderColor(.separatorColor)
                    for edge in [NSRectEdge.minX, .maxX] { cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: edge) }
                    for edge in [NSRectEdge.minY, .maxY] { cell.setWidth(5, type: .absoluteValueType, for: .padding, edge: edge) }
                    if r == 0 { cell.backgroundColor = .quaternarySystemFill }
                    let style = NSMutableParagraphStyle()
                    style.lineSpacing = 2
                    style.textBlocks = context.blocks + [cell]
                    style.alignment = switch alignments[safe: column] ?? nil {
                    case .right: .right
                    case .center: .center
                    default: .natural
                    }
                    let content = cells[safe: column].map { inline($0, Traits(bold: r == 0, color: context.color)) }
                        ?? NSAttributedString(string: "")
                    let paragraph = NSMutableAttributedString(attributedString: content)
                    paragraph.append(NSAttributedString(string: "\n", attributes: [.font: Fonts.body]))
                    paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
                    output.append(paragraph)
                }
            }
        }

        // MARK: Inline

        func inline(_ markup: any Markup, _ traits: Traits) -> NSAttributedString {
            let result = NSMutableAttributedString()
            for child in markup.children { result.append(inlineChild(child, traits)) }
            return result
        }

        private func inlineChild(_ markup: any Markup, _ traits: Traits) -> NSAttributedString {
            switch markup {
            case let text as Markdown.Text:
                return Links.linkified(text.string, attributes: attributes(traits))
            case let code as InlineCode:
                var attrs = attributes(traits)
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: traits.size - 1, weight: traits.bold ? .semibold : .regular)
                attrs[.backgroundColor] = NSColor.quaternarySystemFill
                if let link = Links.fileReference(inCode: code.code, root: renderer.root) { attrs[.link] = link }
                return NSAttributedString(string: code.code, attributes: attrs)
            case is Strong:
                var bold = traits
                bold.bold = true
                return inline(markup, bold)
            case is Emphasis:
                var italic = traits
                italic.italic = true
                return inline(markup, italic)
            case is Strikethrough:
                let s = NSMutableAttributedString(attributedString: inline(markup, traits))
                s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: s.length))
                return s
            case let link as Markdown.Link:
                let s = NSMutableAttributedString(attributedString: inline(link, traits))
                if let url = link.destination.flatMap(Links.destination) {
                    s.addAttribute(.link, value: url, range: NSRange(location: 0, length: s.length))
                }
                return s
            case let image as Markdown.Image:
                return NSAttributedString(string: image.plainText, attributes: attributes(traits))
            case is SoftBreak:
                return NSAttributedString(string: renderer.preserveLineBreaks ? "\u{2028}" : " ", attributes: attributes(traits))
            case is LineBreak:
                return NSAttributedString(string: "\u{2028}", attributes: attributes(traits))
            case let html as InlineHTML:
                return NSAttributedString(string: html.rawHTML, attributes: attributes(traits))
            default:
                return inline(markup, traits)
            }
        }

        private func attributes(_ traits: Traits) -> [NSAttributedString.Key: Any] {
            var font = NSFont.systemFont(ofSize: traits.size, weight: traits.bold ? .semibold : .regular)
            if traits.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            return [.font: font, .foregroundColor: traits.color]
        }
    }
}

// MARK: - Text blocks

/// A code block's rounded fill. `frameRect` spans the block's margins, so they're inset here.
nonisolated final class CodeBlockBackground: NSTextBlock {
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        let rect = NSRect(
            x: frameRect.minX + width(for: .margin, edge: .minX),
            y: frameRect.minY + width(for: .margin, edge: .minY),
            width: frameRect.width - width(for: .margin, edge: .minX) - width(for: .margin, edge: .maxX),
            height: frameRect.height - width(for: .margin, edge: .minY) - width(for: .margin, edge: .maxY)
        )
        NSColor.quaternarySystemFill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
    }
}

/// A block quote's bar.
nonisolated final class QuoteBlock: NSTextBlock {
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        let x = frameRect.minX + width(for: .margin, edge: .minX)
        let top = frameRect.minY + width(for: .margin, edge: .minY)
        let bar = NSRect(x: x, y: top + 1, width: 3, height: frameRect.maxY - top - 2)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// A horizontal rule.
nonisolated final class RuleBlock: NSTextBlock {
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        let top = frameRect.minY + width(for: .margin, edge: .minY)
        NSColor.separatorColor.setFill()
        NSRect(x: frameRect.minX + width(for: .margin, edge: .minX), y: ((top + frameRect.maxY) / 2).rounded(), width: frameRect.width, height: 1).fill()
    }
}

// MARK: - Highlighting

/// highlight.js colors for code blocks, computed off the main thread and cached by code and appearance.
enum Highlighter {
    private static let highlight = Highlight()
    private static var cache: [String: [(NSRange, NSColor)]] = [:]
    private static var pending: Set<String> = []

    private static func key(_ code: String, _ language: String, dark: Bool) -> String {
        "\(dark ? 1 : 0)\(language)\u{0}\(code)"
    }

    /// Colors what's cached; returns the spans still waiting on highlight.js.
    static func apply(to string: NSMutableAttributedString, spans: [CodeSpan], dark: Bool) -> [CodeSpan] {
        var missing: [CodeSpan] = []
        for span in spans {
            guard let language = span.language, !language.isEmpty, span.code.utf8.count < 100_000 else { continue }
            guard let colors = cache[key(span.code, language, dark: dark)] else {
                missing.append(span)
                continue
            }
            for (range, color) in colors where NSMaxRange(range) <= span.range.length {
                string.addAttribute(.foregroundColor, value: color, range: NSRange(location: span.range.location + range.location, length: range.length))
            }
        }
        return missing
    }

    static func request(_ spans: [CodeSpan], dark: Bool, completion: @escaping () -> Void) {
        let wanted = spans.compactMap { span in span.language.map { (span.code, $0) } }
            .filter { pending.insert(key($0.0, $0.1, dark: dark)).inserted }
        guard !wanted.isEmpty else { return }
        Task {
            for (code, language) in wanted {
                let key = key(code, language, dark: dark)
                let colors: HighlightColors = dark ? .dark(.xcode) : .light(.xcode)
                var runs: [(NSRange, NSColor)] = []
                if let result = try? await highlight.request(code, mode: .languageAlias(language), colors: colors) {
                    let attributed = NSAttributedString(result.attributedText)
                    attributed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                        if let color = value as? NSColor { runs.append((range, color)) }
                    }
                }
                if cache.count > 400 { cache.removeAll() }
                cache[key] = runs
                pending.remove(key)
            }
            completion()
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension NSFont {
    var monospacedDigit: NSFont {
        let descriptor = fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
