import SwiftUI

struct SessionView: View {
    @Environment(Store.self) private var store
    let session: Session

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(session.entries.enumerated()), id: \.element.id) { index, entry in
                    EntryView(entry: entry)
                        .padding(.top, index == 0 ? 0 : spacing(before: entry, after: session.entries[index - 1]))
                }
                if session.isRunning, session.entries.last?.kind != .assistant {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 16)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .environment(\.projectRoot, session.project.url)
        .environment(\.openURL, OpenURLAction { Links.open($0, root: session.project.url) })
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if !session.queue.isEmpty {
                    QueueView(session: session, draft: store.draft(for: session.id))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                composer
            }
            .animation(.snappy, value: session.queue.map(\.id))
        }
        .modifier(AttachmentDrop(draft: store.draft(for: session.id)))
        .navigationTitle(session.title)
        .navigationSubtitle(session.project.name)
        .toolbar {
            ToolbarItemGroup {
                Button("Open in Terminal", systemImage: "apple.terminal") {
                    let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                    NSWorkspace.shared.open([session.project.url], withApplicationAt: terminal, configuration: .init(), completionHandler: nil)
                }
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([session.project.url])
                }
            }
        }
        .task { await session.loadIfNeeded() }
    }

    private var composer: some View {
        Composer(
            draft: store.draft(for: session.id),
            isRunning: session.isRunning,
            onSend: { session.send($0, attachments: $1, config: store.config) },
            onStop: session.stop
        )
    }

    /// Tool calls cluster tightly; a new speaker gets room to breathe.
    private func spacing(before entry: Entry, after previous: Entry) -> CGFloat {
        switch (previous.kind, entry.kind) {
        case (.tool, .tool), (.thinking, .tool), (.tool, .thinking): 6
        case (_, .user), (.user, _): 28
        default: 18
        }
    }
}

/// Follow-ups waiting for the current turn to end, t3-style: edit, send now, or drop each one.
private struct QueueView: View {
    let session: Session
    let draft: Draft

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(session.isQueuePaused ? "Queue paused" : "Queued", systemImage: "text.line.last.and.arrowtriangle.forward")
                Spacer()
                if session.isQueuePaused {
                    Button("Resume", action: session.resumeQueue)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            ForEach(session.queue) { message in
                HStack(spacing: 8) {
                    if !message.attachments.isEmpty {
                        Image(systemName: "paperclip")
                            .foregroundStyle(.secondary)
                    }
                    Text(message.text.isEmpty ? message.attachments.map(\.name).joined(separator: ", ") : message.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Group {
                        Button("Edit", systemImage: "pencil") { edit(message) }
                        Button("Send Now", systemImage: "arrow.up.circle") { session.sendNow(message) }
                        Button("Remove", systemImage: "xmark") { session.queue.removeAll { $0.id == message.id } }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.quinary, in: .rect(cornerRadius: 10))
            }
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .frame(maxWidth: .infinity)
        .background(.background)
    }

    /// Pulls a queued message back into the composer, keeping whatever is already typed.
    private func edit(_ message: QueuedMessage) {
        session.queue.removeAll { $0.id == message.id }
        draft.text = [message.text, draft.text].filter { !$0.isEmpty }.joined(separator: "\n")
        draft.attachments = message.attachments + draft.attachments
    }
}
