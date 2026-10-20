import SwiftUI
import UniformTypeIdentifiers

struct Composer: View {
    @Environment(Store.self) private var store
    let draft: Draft
    let isRunning: Bool
    let onSend: (String, [Attachment]) -> Void
    let onStop: () -> Void

    @FocusState private var isFocused: Bool
    @State private var pasteMonitor: Any?
    @State private var dictation = Dictation()
    @AppStorage(Pref.readingWidth) private var readingWidth = ReadingWidth.standard

    var body: some View {
        @Bindable var store = store
        @Bindable var draft = draft
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                if !draft.attachments.isEmpty {
                    AttachmentStrip(draft: draft)
                }
                // Icons and a one-line field share the same 28pt row, so everything sits on one center line;
                // when the text wraps, the icons stay beside the last line.
                HStack(alignment: .bottom, spacing: 8) {
                    ComposerButton("Attach Files", symbol: "plus", weight: .medium, action: chooseFiles)
                        .help("Attach images or files (you can also drop or paste them)")
                        .tint(.primary)

                    TextField(placeholder, text: $draft.text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .lineLimit(1...12)
                        .focused($isFocused)
                        .onSubmit(send)
                        .frame(minHeight: ComposerButton.size)

                    ComposerButton(dictation.isRecording ? "Stop Dictation" : "Dictate", symbol: dictation.isRecording ? "mic.fill" : "mic", action: toggleDictation)
                        .foregroundStyle(dictation.isRecording ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .symbolEffect(.pulse, isActive: dictation.isRecording)
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                        .help(dictation.isRecording ? "Stop dictation (⇧⌘D)" : "Dictate (⇧⌘D)")

                    if isRunning {
                        ComposerButton("Stop", symbol: "stop.circle.fill", action: onStop)
                            .keyboardShortcut(".", modifiers: .command)
                    }
                    if !isRunning || !draft.isEmpty {
                        ComposerButton(isRunning ? "Queue" : "Send", symbol: isRunning ? "text.line.last.and.arrowtriangle.forward" : "arrow.up.circle.fill", action: send)
                            .help(isRunning ? "Queue — sent when Claude finishes this turn" : "Send")
                            .disabled(draft.isEmpty)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .glassEffect(in: .rect(cornerRadius: 20))

            if let error = dictation.error {
                Label(error, systemImage: "mic.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
            }

            HStack(spacing: 16) {
                if store.selectedSession == nil {
                    OptionMenu(symbol: "folder", title: store.draftProject?.name ?? "Choose Project", selection: $store.draftProject) {
                        ForEach(store.projects) { Text($0.name).tag(Optional($0)) }
                    }
                }
                OptionMenu(symbol: "hand.raised", title: store.config.mode.label, selection: $store.config.mode) {
                    ForEach(PermissionMode.allCases) { Text($0.label).tag($0) }
                }
                Spacer()
                ModelMenu()
                if let effort = store.config.effort, !store.efforts.isEmpty {
                    OptionMenu(symbol: "gauge.with.dots.needle.50percent", title: effort.label, selection: $store.config.effort) {
                        ForEach(store.efforts) { Text($0.label).tag(Optional($0)) }
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: readingWidth.maxWidth)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background {
            // Fade the transcript out beneath the composer.
            Rectangle()
                .fill(.transcriptBackground)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.35)], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()
        }
        .defaultFocus($isFocused, true)
        .task { isFocused = true }
        .onAppear(perform: installPasteMonitor)
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            dictation.stop()
        }
    }

    private var placeholder: String {
        if dictation.isRecording { return "Listening…" }
        return isRunning ? "Queue a follow-up…" : "Ask Claude to build, fix, or explain…"
    }

    /// Speech lands after whatever is already typed, and keeps replacing its own words as the recognizer revises them.
    private func toggleDictation() {
        if dictation.isRecording {
            dictation.stop()
            return
        }
        let draft = draft
        let typed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = typed.isEmpty ? "" : typed + " "
        isFocused = true
        Task { await dictation.start { draft.text = prefix + $0 } }
    }

    private func send() {
        dictation.stop()
        guard !draft.isEmpty else { return }
        onSend(draft.text.trimmingCharacters(in: .whitespacesAndNewlines), draft.attachments)
        draft.clear()
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.directoryURL = store.selectedSession?.project.url ?? store.draftProject?.url
        guard panel.runModal() == .OK else { return }
        draft.add(panel.urls)
        isFocused = true
    }

    /// ⌘V with an image or files on the pasteboard attaches them; text pastes as usual.
    private func installPasteMonitor() {
        let draft = draft
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  event.window?.firstResponder is NSTextView,
                  draft.paste(from: .general)
            else { return event }
            return nil
        }
    }
}

private struct AttachmentStrip: View {
    let draft: Draft

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(draft.attachments) { attachment in
                    AttachmentChip(attachment: attachment)
                        .overlay(alignment: .topTrailing) {
                            Button("Remove", systemImage: "xmark.circle.fill") {
                                withAnimation { draft.attachments.removeAll { $0.id == attachment.id } }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                            .font(.body)
                            .offset(x: 6, y: -6)
                        }
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

struct AttachmentChip: View {
    let attachment: Attachment
    var size: CGFloat = 56

    var body: some View {
        if let data = attachment.imageData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                .help(attachment.name)
        } else if case .file(let url) = attachment.kind {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 28, height: 28)
                Text(attachment.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160, alignment: .leading)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: size)
            .background(.quinary, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .help(url.path)
        }
    }
}

/// A composer icon in a fixed square, so different symbols share one optical center.
private struct ComposerButton: View {
    static let size: CGFloat = 28

    let title: String
    let symbol: String
    var weight: Font.Weight = .regular
    let action: () -> Void

    init(_ title: String, symbol: String, weight: Font.Weight = .regular, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.weight = weight
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbol.hasSuffix(".fill") ? 22 : 17, weight: weight))
                .frame(width: Self.size, height: Self.size)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
    }
}

/// Lets a whole pane accept dropped files, with a quiet highlight while dragging.
struct AttachmentDrop: ViewModifier {
    let draft: Draft
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted) { providers in
                receive(providers)
                return true
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .background(.tint.opacity(0.06), in: .rect(cornerRadius: 16))
                        .overlay {
                            Label("Drop to Attach", systemImage: "paperclip")
                                .font(.title3.weight(.medium))
                                .foregroundStyle(.tint)
                        }
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
    }

    /// Finder files arrive as file URLs; images dragged from a browser or Photos arrive as data.
    private func receive(_ providers: [NSItemProvider]) {
        let draft = draft
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { draft.add([url]) } }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let attachment = Attachment.image(data, name: provider.suggestedName ?? "Dropped Image") else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { draft.attachments.append(attachment) } }
                }
            }
        }
    }
}

/// Every model `/model` lists, each with its description as a subtitle.
/// Toggles rather than a Picker: a Picker drops the subtitle, and a Button inside one swallows the selection.
private struct ModelMenu: View {
    @Environment(Store.self) private var store

    var body: some View {
        Menu {
            ForEach(store.models) { model in
                Toggle(isOn: Binding(get: { store.config.model == model.value }, set: { _ in store.selectModel(model.value) })) {
                    Text(model.displayName)
                    if !model.description.isEmpty { Text(model.description) }
                }
            }
        } label: {
            Label(store.model.shortLabel, systemImage: "cpu")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        // Quiet chrome: stays gray whatever accent color is chosen.
        .tint(.secondary)
        .fixedSize()
        .foregroundStyle(.secondary)
    }
}

/// A quiet, borderless footer menu in the style of Claude Desktop.
private struct OptionMenu<Value: Hashable, Content: View>: View {
    let symbol: String
    let title: String
    @Binding var selection: Value
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            Picker(title, selection: $selection) { content }
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            Label(title, systemImage: symbol)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        // Quiet chrome: stays gray whatever accent color is chosen.
        .tint(.secondary)
        .fixedSize()
        .foregroundStyle(.secondary)
    }
}
