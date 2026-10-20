import SwiftUI

/// Equatable on its entry alone: in a long session, a streaming token re-renders only the row it lands in.
struct EntryView: View, Equatable {
    let entry: Entry

    nonisolated static func == (a: EntryView, b: EntryView) -> Bool { a.entry == b.entry }

    @Environment(\.textSize) private var textSize
    @AppStorage(Pref.bubbleStyle) private var bubbleStyle = BubbleStyle.gray
    @AppStorage(Pref.expandThinking) private var expandThinking = false
    /// Nil until toggled by hand, so it follows the "expand by default" setting.
    @State private var isThinkingOpen: Bool?
    @State private var isHovered = false

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
                .overlay(alignment: .topTrailing) { SpeakButton(entry: entry, isHovered: isHovered) }
                .onHover { isHovered = $0 }
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
        VStack(alignment: .leading, spacing: 8) {
            disclosure
            // Images a tool returned (a screenshot it read) show right away, not behind the disclosure.
            if !tool.images.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(tool.images.enumerated()), id: \.offset) { _, data in
                        ImageThumbnail(data: data)
                    }
                }
                .padding(.leading, 22)
            }
        }
    }

    private var disclosure: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if tool.isFileEdit, !tool.isError, case let hunks = tool.diffHunks, !hunks.isEmpty {
                    DiffView(hunks: hunks)
                } else if let command = tool.input?["command"]?.string {
                    CodeBlockView(code: command, language: "bash")
                } else if let input = tool.input {
                    CodeBlockView(code: input.pretty, language: "json")
                }
                // An edit's "file updated" note adds nothing next to its diff.
                if let result = tool.result, !result.isEmpty, !tool.isFileEdit || tool.isError {
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
                if let stats = tool.diffStats {
                    HStack(spacing: 4) {
                        if stats.added > 0 { Text("+\(stats.added)").foregroundStyle(.green) }
                        if stats.removed > 0 { Text("−\(stats.removed)").foregroundStyle(.red) }
                    }
                    .font(.system(size: textSize - 1, design: .monospaced))
                    .fixedSize()
                }
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

/// A sent or returned image; click to open it full size in Preview.
private struct ImageThumbnail: View {
    let data: Data

    var body: some View {
        if let image = Thumbnails.image(for: data) {
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

/// Small decoded copies of transcript images. Tool screenshots run to several megapixels, and a row
/// shouldn't decode one in full every time it's drawn.
private enum Thumbnails {
    private static let cache: NSCache<NSData, NSImage> = {
        let cache = NSCache<NSData, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    static func image(for data: Data) -> NSImage? {
        let key = data as NSData
        if let cached = cache.object(forKey: key) { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480, // 240pt at 2x
        ]
        guard let source = CGImageSourceCreateWithData(key, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width / 2, height: thumbnail.height / 2))
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Reads a reply aloud; shown while hovering the reply, and kept while it's being read so it can stop it.
private struct SpeakButton: View {
    let entry: Entry
    let isHovered: Bool
    private var speaker: Speaker { .shared }

    var body: some View {
        let speaking = speaker.isSpeaking(entry)
        if speaking, speaker.isPreparing {
            // Loading the voice model (or downloading it, the first time) before the first words.
            ProgressView()
                .controlSize(.small)
                .padding(4)
                .help("Preparing the voice…")
        } else if isHovered || speaking {
            Button(speaking ? "Stop Reading" : "Read Aloud", systemImage: speaking ? "stop.circle.fill" : "speaker.wave.2") {
                if speaking { speaker.stop() } else { speaker.speak([entry]) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(speaking ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .padding(4)
            .background(.background.opacity(0.85), in: .circle)
            .help(speaking ? "Stop reading" : "Read aloud")
            .transition(.opacity)
        }
    }
}
