import SwiftUI

struct EntryView: View {
    let entry: Entry

    var body: some View {
        switch entry.kind {
        case .user:
            VStack(alignment: .trailing, spacing: 8) {
                if !entry.images.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(entry.images.enumerated()), id: \.offset) { _, data in
                            ImageThumbnail(data: data)
                        }
                    }
                }
                if !entry.files.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(entry.files, id: \.self) { name in
                            Label(name, systemImage: "doc")
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.quinary, in: .capsule)
                        }
                    }
                }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.quaternary, in: .rect(cornerRadius: 16))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 80)
        case .assistant:
            MarkdownView(text: entry.text)
        case .thinking:
            DisclosureGroup("Thinking") {
                Text(entry.text)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }
            .foregroundStyle(.secondary)
        case .tool:
            if let tool = entry.tool { ToolView(tool: tool) }
        case .error:
            Label(entry.text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

struct ToolView: View {
    let tool: ToolCall
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let command = tool.input?["command"]?.string {
                    CodeBlockView(code: command, language: "bash")
                } else if let input = tool.input {
                    CodeBlockView(code: input.pretty, language: "json")
                }
                if let result = tool.result, !result.isEmpty {
                    CodeBlockView(code: String(result.prefix(20_000)))
                        .foregroundStyle(tool.isError ? .red : .primary)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tool.symbol)
                    .frame(width: 16)
                Text(tool.title)
                Text(tool.summary)
                    .font(.callout.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if tool.result == nil {
                    ProgressView().controlSize(.mini)
                } else if tool.isError {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .foregroundStyle(.secondary)
            .contentShape(.rect)
            .onTapGesture { withAnimation { isExpanded.toggle() } }
        }
    }
}

/// A sent image; click to open it full size in Preview.
private struct ImageThumbnail: View {
    let data: Data

    var body: some View {
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240, maxHeight: 180)
                .clipShape(.rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                .onTapGesture(perform: open)
                .help("Open in Preview")
        }
    }

    private func open() {
        let ext = data.starts(with: [0x89, 0x50]) ? "png" : "jpg"
        let url = FileManager.default.temporaryDirectory.appending(path: "hypercode-\(abs(data.hashValue)).\(ext)")
        try? data.write(to: url)
        NSWorkspace.shared.open(url)
    }
}
