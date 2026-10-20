import SwiftUI

/// A file change as a unified diff: line numbers, red removals, green additions, and within a changed line,
/// the part that actually changed picked out a shade stronger.
struct DiffView: View {
    let hunks: [DiffHunk]
    @Environment(\.textSize) private var textSize

    /// Past this, the rest is summarized; a 2,000-line Write shouldn't become 2,000 views.
    private static let maxRows = 400

    var body: some View {
        let rows = DiffRow.rows(for: hunks)
        let shown = rows.prefix(Self.maxRows)
        let numbered = hunks.contains { $0.oldStart > 0 || $0.newStart > 0 }
        let digits = max(2, String(rows.compactMap { max($0.old ?? 0, $0.new ?? 0) }.max() ?? 0).count)
        let gutter = CGFloat(digits) * (textSize - 1) * 0.62 + 8

        VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { row in
                if row.kind == .gap {
                    Text("⋯")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.5))
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        if numbered {
                            number(row.old, width: gutter)
                            number(row.new, width: gutter)
                        }
                        Text(row.sign)
                            .foregroundStyle(row.kind.accent ?? .secondary)
                            .frame(width: 18)
                        Text(row.attributed(changed: row.kind.accent?.opacity(0.32)))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 1)
                    .background(row.kind.accent?.opacity(0.14) ?? .clear)
                }
            }
            if rows.count > shown.count {
                Text("\(rows.count - shown.count) more lines")
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .font(.system(size: textSize - 1, design: .monospaced))
        .textSelection(.enabled)
        .padding(.vertical, 6)
        .background(.quinary, in: .rect(cornerRadius: 10))
        .clipShape(.rect(cornerRadius: 10))
    }

    private func number(_ value: Int?, width: CGFloat) -> some View {
        // A space, not "": an empty Text has no baseline, which would make the row taller.
        Text(value.map(String.init) ?? " ")
            .foregroundStyle(.tertiary)
            .frame(width: width, alignment: .trailing)
            .padding(.trailing, 4)
    }
}

/// One drawn line of a diff, with its old and new line numbers and, when paired with a line it replaces,
/// the range of characters that differ.
struct DiffRow: Identifiable {
    enum Kind {
        case context, removed, added, gap

        var accent: Color? {
            switch self {
            case .removed: .red
            case .added: .green
            default: nil
            }
        }
    }

    let id: Int
    let kind: Kind
    var old: Int?
    var new: Int?
    let text: String
    /// What changed against the paired line, as character offsets into `text`.
    var changed: Range<Int>?

    var sign: String {
        switch kind {
        case .removed: "-"
        case .added: "+"
        default: " "
        }
    }

    func attributed(changed color: Color?) -> AttributedString {
        var result = AttributedString(text.isEmpty ? " " : text)
        guard let changed, let color, changed.count < text.count else { return result }
        let start = result.index(result.startIndex, offsetByCharacters: changed.lowerBound)
        let end = result.index(start, offsetByCharacters: changed.count)
        result[start..<end].backgroundColor = color
        return result
    }

    static func rows(for hunks: [DiffHunk]) -> [DiffRow] {
        var rows: [DiffRow] = []
        for (h, hunk) in hunks.enumerated() {
            if h > 0 { rows.append(DiffRow(id: rows.count, kind: .gap, text: "")) }
            var old = hunk.oldStart, new = hunk.newStart
            let numbered = hunk.oldStart > 0 || hunk.newStart > 0
            for line in hunk.lines {
                let text = String(line.dropFirst())
                switch line.first {
                case "-":
                    rows.append(DiffRow(id: rows.count, kind: .removed, old: numbered ? old : nil, text: text))
                    old += 1
                case "+":
                    rows.append(DiffRow(id: rows.count, kind: .added, new: numbered ? new : nil, text: text))
                    new += 1
                case "\\":
                    continue // "\ No newline at end of file"
                default:
                    rows.append(DiffRow(id: rows.count, kind: .context, old: numbered ? old : nil, new: numbered ? new : nil, text: text))
                    old += 1
                    new += 1
                }
            }
        }
        markChanges(in: &rows)
        return rows
    }

    /// Pairs each run of removals with the additions right after it, line by line, and marks the middle
    /// that differs once the shared start and end are set aside. Lines that share little stay unmarked.
    private static func markChanges(in rows: inout [DiffRow]) {
        var i = 0
        while i < rows.count {
            guard rows[i].kind == .removed else { i += 1; continue }
            var removedEnd = i
            while removedEnd < rows.count, rows[removedEnd].kind == .removed { removedEnd += 1 }
            var addedEnd = removedEnd
            while addedEnd < rows.count, rows[addedEnd].kind == .added { addedEnd += 1 }
            for k in 0..<min(removedEnd - i, addedEnd - removedEnd) {
                let a = Array(rows[i + k].text), b = Array(rows[removedEnd + k].text)
                var prefix = 0
                while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
                var suffix = 0
                while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
                // Mostly rewritten lines read better whole-colored than speckled.
                guard prefix + suffix >= max(a.count, b.count) / 3 else { continue }
                rows[i + k].changed = prefix..<(a.count - suffix)
                rows[removedEnd + k].changed = prefix..<(b.count - suffix)
            }
            i = addedEnd
        }
    }
}

extension ToolCall {
    /// The diff to draw: Claude Code's own patch when it recorded one, else one computed from the edit's input.
    var diffHunks: [DiffHunk] {
        if let patch, !patch.isEmpty { return patch }
        guard let input else { return [] }
        switch name {
        case "Edit":
            return [DiffHunk.between(input["old_string"]?.string ?? "", input["new_string"]?.string ?? "")]
        case "MultiEdit":
            return (input["edits"]?.array ?? []).map {
                DiffHunk.between($0["old_string"]?.string ?? "", $0["new_string"]?.string ?? "")
            }
        case "Write":
            let lines = (input["content"]?.string ?? "").components(separatedBy: "\n")
            return [DiffHunk(oldStart: 0, newStart: 1, lines: lines.map { "+" + $0 })]
        default:
            return []
        }
    }

    /// Lines added and removed, for the row's "+12 −3".
    var diffStats: (added: Int, removed: Int)? {
        guard isFileEdit else { return nil }
        let lines = diffHunks.flatMap(\.lines)
        let added = lines.count { $0.hasPrefix("+") }, removed = lines.count { $0.hasPrefix("-") }
        return added + removed > 0 ? (added, removed) : nil
    }
}
