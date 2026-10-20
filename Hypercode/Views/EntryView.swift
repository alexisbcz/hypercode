import SwiftUI

struct EntryView: View {
    let entry: Entry
    @Environment(\.textSize) private var textSize
    @AppStorage(Pref.bubbleStyle) private var bubbleStyle = BubbleStyle.gray
    @AppStorage(Pref.expandThinking) private var expandThinking = false
    /// Nil until toggled by hand, so it follows the "expand by default" setting.
    @State private var isThinkingOpen: Bool?

    var body: some View {
        switch entry.kind {
        case .user:
            let plain = bubbleStyle == .plain
            VStack(alignment: plain ? .leading : .trailing, spacing: 8) {
                if plain {
                    Text("You")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
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
                                .font(.system(size: textSize - 1))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.quinary, in: .capsule)
                        }
                    }
                }
                if !entry.text.isEmpty {
                    bubble(Text(Links.linkified(entry.text)).textSelection(.enabled))
                }
            }
            .frame(maxWidth: .infinity, alignment: plain ? .leading : .trailing)
            .padding(.leading, plain ? 0 : 80)
        case .assistant:
            MarkdownView(text: entry.text)
        case .thinking:
            DisclosureGroup("Thinking", isExpanded: Binding(get: { isThinkingOpen ?? expandThinking }, set: { isThinkingOpen = $0 })) {
                Text(entry.text)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }
            .foregroundStyle(.secondary)
        case .tool:
            if let tool = entry.tool { ToolView(tool: tool) }
        case .command:
            // A slash command the user ran: "/context", the name in the accent color.
            Text(entry.text)
                .font(.system(size: textSize - 0.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tint)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.quaternary, in: .rect(cornerRadius: 16))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .notice:
            // What a command printed (/context, /usage…), or a note like "Conversation compacted".
            MarkdownView(text: entry.text)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.quinary, in: .rect(cornerRadius: 10))
        case .error:
            Label(entry.text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    /// Your message as the "Your messages" setting draws it.
    @ViewBuilder
    private func bubble(_ text: some View) -> some View {
        switch bubbleStyle {
        case .gray:
            text
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.quaternary, in: .rect(cornerRadius: 16))
        case .tinted:
            text
                .foregroundStyle(.white)
                .tint(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.tint, in: .rect(cornerRadius: 16))
        case .plain:
            text
        }
    }
}

struct ToolView: View {
    let tool: ToolCall
    @Environment(\.textSize) private var textSize
    @AppStorage(Pref.expandTools) private var expandTools = false
    /// Nil until toggled by hand, so it follows the "expand by default" setting.
    @State private var isOpen: Bool?

    private var isExpanded: Binding<Bool> {
        Binding(get: { isOpen ?? expandTools }, set: { isOpen = $0 })
    }

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
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
                    .font(.system(size: textSize - 1, design: .monospaced))
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
            .onTapGesture { withAnimation { isExpanded.wrappedValue.toggle() } }
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
