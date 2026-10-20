import HighlightSwift
import Markdown
import SwiftUI

/// Renders GitHub-flavored Markdown with native SwiftUI views.
struct MarkdownView: View {
    let text: String

    var body: some View {
        BlockChildren(parent: Document(parsing: text, options: [.parseBlockDirectives]))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlockChildren: View {
    let parent: any Markup
    /// Nil for the message's own blocks, which follow the Spacing setting.
    var spacing: CGFloat?
    @Environment(\.density) private var density

    var body: some View {
        VStack(alignment: .leading, spacing: spacing ?? density.blockSpacing) {
            ForEach(Array(parent.children.enumerated()), id: \.offset) { _, child in
                Block(markup: child)
            }
        }
    }
}

private struct Block: View {
    let markup: any Markup
    @Environment(\.projectRoot) private var root
    @Environment(\.textSize) private var textSize
    @Environment(\.density) private var density

    var body: some View {
        if let paragraph = markup as? Paragraph {
            SwiftUI.Text(Inline.render(paragraph, root: root))
                .lineSpacing(density.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        } else if let heading = markup as? Heading {
            SwiftUI.Text(Inline.render(heading, root: root))
                .font(.system(size: textSize * Self.scale(for: heading.level), weight: .semibold))
                .padding(.top, heading.level <= 2 ? 8 : 4)
        } else if let code = markup as? CodeBlock {
            CodeBlockView(code: code.code.trimmingCharacters(in: .newlines), language: code.language)
        } else if let list = markup as? UnorderedList {
            ListView(list: list, ordered: false, start: 1)
        } else if let list = markup as? OrderedList {
            ListView(list: list, ordered: true, start: Int(list.startIndex))
        } else if let quote = markup as? BlockQuote {
            HStack(spacing: 12) {
                Capsule().fill(.quaternary).frame(width: 3)
                BlockChildren(parent: quote, spacing: 8)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else if let table = markup as? Markdown.Table {
            TableView(table: table)
        } else if markup is ThematicBreak {
            Divider().padding(.vertical, 4)
        } else if let html = markup as? HTMLBlock {
            SwiftUI.Text(html.rawHTML).font(.system(size: textSize, design: .monospaced)).foregroundStyle(.secondary)
        } else {
            BlockChildren(parent: markup)
        }
    }

    /// Heading sizes relative to the body, so the text-size setting scales them too.
    static func scale(for level: Int) -> CGFloat {
        switch level {
        case 1: 1.7
        case 2: 1.35
        case 3: 1.15
        default: 1
        }
    }
}

private struct ListView: View {
    let list: any ListItemContainer
    let ordered: Bool
    let start: Int
    @Environment(\.density) private var density

    var body: some View {
        let spacing = (density.blockSpacing * 0.45).rounded()
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(list.listItems.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(index: index, item: item)
                    BlockChildren(parent: item, spacing: spacing)
                }
            }
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private func marker(index: Int, item: ListItem) -> some View {
        if let checkbox = item.checkbox {
            Image(systemName: checkbox == .checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checkbox == .checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        } else if ordered {
            SwiftUI.Text("\(start + index).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
        } else {
            SwiftUI.Text("•")
                .foregroundStyle(.secondary)
                .frame(minWidth: 10)
        }
    }
}

private struct TableView: View {
    @Environment(\.projectRoot) private var root
    let table: Markdown.Table

    var body: some View {
        let header = Array(table.head.cells)
        let rows = table.body.rows.map { Array($0.cells) }
        let alignments = table.columnAlignments

        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                    cellView(cell, alignment: alignments[safe: column] ?? nil)
                        .fontWeight(.semibold)
                }
            }
            .background(.quinary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider()
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        cellView(cell, alignment: alignments[safe: column] ?? nil)
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .clipShape(.rect(cornerRadius: 10))
    }

    private func cellView(_ cell: Markdown.Table.Cell, alignment: Markdown.Table.ColumnAlignment?) -> some View {
        SwiftUI.Text(Inline.render(cell, root: root))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment == .right ? .trailing : alignment == .center ? .center : .leading)
            .gridColumnAlignment(alignment == .right ? .trailing : alignment == .center ? .center : .leading)
    }
}

/// Inline Markdown → AttributedString, so text wraps and selects as one run.
private enum Inline {
    static func render(_ markup: any Markup, root: URL?) -> AttributedString {
        markup.children.reduce(into: AttributedString()) { $0 += render(inline: $1, root: root) }
    }

    private static func render(inline markup: any Markup, root: URL?) -> AttributedString {
        switch markup {
        case let text as Markdown.Text:
            return Links.linkified(text.string)
        case let code as InlineCode:
            var s = AttributedString(code.code)
            // The code intent sets in monospace at the surrounding size, so it follows the text-size setting.
            s.inlinePresentationIntent = .code
            s.backgroundColor = Color.secondary.opacity(0.12)
            s.link = Links.fileReference(inCode: code.code, root: root)
            return s
        case is Strong:
            return styled(markup, .stronglyEmphasized, root: root)
        case is Emphasis:
            return styled(markup, .emphasized, root: root)
        case is Strikethrough:
            var s = render(markup, root: root)
            s.strikethroughStyle = .single
            return s
        case let link as Markdown.Link:
            var s = render(link, root: root)
            if let url = link.destination.flatMap(Links.destination) { s.link = url }
            return s
        case let image as Markdown.Image:
            return AttributedString(image.plainText)
        case is SoftBreak:
            return AttributedString(" ")
        case is LineBreak:
            return AttributedString("\n")
        case let html as InlineHTML:
            return AttributedString(html.rawHTML)
        default:
            return render(markup, root: root)
        }
    }

    private static func styled(_ markup: any Markup, _ intent: InlinePresentationIntent, root: URL?) -> AttributedString {
        var s = render(markup, root: root)
        for run in s.runs {
            let current = s[run.range].inlinePresentationIntent ?? []
            s[run.range].inlinePresentationIntent = current.union(intent)
        }
        return s
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Code

struct CodeBlockView: View {
    let code: String
    var language: String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.textSize) private var textSize
    @AppStorage(Pref.codeTheme) private var theme = HighlightTheme.xcode
    @State private var highlighted: AttributedString?
    @State private var copied = false
    /// Set after the first pass: later changes are a block still streaming in, so they wait for a pause.
    @State private var hasHighlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SwiftUI.Text(language ?? "")
                    .font(.system(size: textSize - 2))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.system(size: textSize - 2))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView(.horizontal) {
                SwiftUI.Text(highlighted ?? AttributedString(code))
                    .font(.system(size: textSize - 1, design: .monospaced))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: .rect(cornerRadius: 10))
        .task(id: "\(colorScheme)\(theme.rawValue)\(code)") {
            if hasHighlighted {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
            }
            hasHighlighted = true
            // Plain output (a tool's stdout, say) gets its web addresses linked instead of colors.
            highlighted = await Highlighter.highlight(code, language: language, theme: theme, dark: colorScheme == .dark)
                ?? (language == nil ? Links.linkified(code) : nil)
        }
    }
}

enum Highlighter {
    private static let highlight = Highlight()
    /// Lazy stacks rebuild rows scrolled back into view; their code shouldn't go back through highlight.js.
    private static var cache: [String: AttributedString] = [:]

    static func highlight(_ code: String, language: String?, theme: HighlightTheme, dark: Bool) async -> AttributedString? {
        guard let language, !language.isEmpty, code.utf8.count < 100_000 else { return nil }
        let key = "\(theme.rawValue)|\(dark)|\(language)|\(code)"
        if let cached = cache[key] { return cached }
        let result = await colored(code, language: language, theme: theme, dark: dark)
        if cache.count > 300 { cache.removeAll() }
        cache[key] = result
        return result
    }

    private static func colored(_ code: String, language: String, theme: HighlightTheme, dark: Bool) async -> AttributedString? {
        let colors: HighlightColors = dark ? .dark(theme) : .light(theme)
        guard var result = try? await highlight.request(code, mode: .languageAlias(language), colors: colors).attributedText
        else { return nil }
        // highlight.js colors arrive as AppKit attributes; hand them to SwiftUI.
        for run in result.runs {
            if let color = run.appKit.foregroundColor {
                result[run.range].appKit.foregroundColor = nil
                result[run.range].swiftUI.foregroundColor = Color(nsColor: color)
            }
        }
        return result
    }
}
