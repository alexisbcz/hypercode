import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let session = store.selectedSession {
                SessionView(session: session)
                    .id(session.id)
            } else {
                NewSessionView()
            }
        }
        #if DEBUG
        // HYPERCODE_OPEN_SETTINGS=1 opens Settings at launch, for checking it by eye.
        .task {
            if ProcessInfo.processInfo.environment["HYPERCODE_OPEN_SETTINGS"] != nil { openSettings() }
        }
        #endif
    }
}

struct Sidebar: View {
    @Environment(Store.self) private var store
    @State private var search = ""
    @State private var expanded: Set<String> = []
    /// Sessions listed per project before "Show More"; 0 lists them all.
    @AppStorage(Pref.sidebarSessions) private var sessionsShown = 5

    private var limit: Int { sessionsShown > 0 ? sessionsShown : .max }

    var body: some View {
        @Bindable var store = store
        List {
            ForEach(store.projects) { project in
                Section {
                    let all = store.sessions(in: project).filter(matches)
                    let showAll = expanded.contains(project.id) || !search.isEmpty
                    ForEach(showAll ? all : Array(all.prefix(limit))) { session in
                        SessionRow(session: session)
                    }
                    if all.count > limit, search.isEmpty {
                        Button(showAll ? "Show Less" : "Show \(all.count - limit) More") {
                            if showAll { expanded.remove(project.id) } else { expanded.insert(project.id) }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    ProjectHeader(project: project)
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
        .overlay {
            if store.projects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder")
                } description: {
                    Text("Open a folder to start working with Claude.")
                } actions: {
                    Button("Open Project…") { store.openProject() }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("New Session", systemImage: "square.and.pencil") { store.newSession() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("Open Project…", systemImage: "folder.badge.plus") { store.openProject() }
                .buttonStyle(.borderless)
                .tint(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }

    private func matches(_ session: Session) -> Bool {
        search.isEmpty || session.title.localizedCaseInsensitiveContains(search)
    }
}

private struct ProjectHeader: View {
    @Environment(Store.self) private var store
    let project: Project

    var body: some View {
        HStack {
            Text(project.name)
            Spacer()
            Button("New Session in \(project.name)", systemImage: "plus") { store.newSession(in: project) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .tint(.primary)
                .padding(.trailing, 8)
        }
        .padding(.bottom, 6)
        .contextMenu {
            Button("New Session") { store.newSession(in: project) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
            Divider()
            Button("Remove Project", role: .destructive) { store.removeProject(project) }
        }
    }
}

private struct SessionRow: View {
    @Environment(Store.self) private var store
    let session: Session

    @State private var isRenaming = false
    @State private var newTitle = ""

    @Environment(\.appearsActive) private var appearsActive
    @AppStorage(Pref.sidebarDates) private var showsDates = true

    private var isSelected: Bool { store.selection == session.id }

    var body: some View {
        HStack {
            Text(session.title)
                .lineLimit(1)
            Spacer()
            if store.isBusy(session) {
                ProgressView().controlSize(.mini)
            } else if showsDates {
                Text(session.date, format: .relative(presentation: .named, unitsStyle: .narrow))
                    .font(.caption)
                    .foregroundStyle(isSelected && appearsActive ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
            }
        }
        .foregroundStyle(isSelected && appearsActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.vertical, 3)
        .contentShape(.rect)
        .onTapGesture { store.selection = session.id }
        // System Settings–style selection: accent pill while active, gray when the window isn't key.
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? (appearsActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.secondary)) : AnyShapeStyle(.clear))
                .padding(.horizontal, 10)
        )
        .contextMenu {
            Button("Rename…") {
                newTitle = session.title
                isRenaming = true
            }
            Button("Resume in Terminal") { store.resumeInTerminal(session) }
            Divider()
            Button("Copy Session ID") { copy(session.id) }
            Button("Copy Resume Command") { copy("claude --resume \(session.id)") }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([Transcript.file(for: session.project.url, session: session.id)])
            }
            Divider()
            Button("Move to Trash", role: .destructive) { store.trash(session) }
        }
        .alert("Rename Session", isPresented: $isRenaming) {
            TextField("Title", text: $newTitle)
            Button("Rename") { store.rename(session, to: newTitle) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

struct NewSessionView: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack {
            Spacer()
            Text("What should we build?")
                .font(.largeTitle)
                .fontWeight(.semibold)
            if let project = store.draftProject {
                Text(project.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Composer(draft: store.draft(for: "new"), isRunning: false, onSend: { store.submit($0, attachments: $1, in: nil) }, onStop: {})
                .disabled(store.draftProject == nil)
        }
        .modifier(AttachmentDrop(draft: store.draft(for: "new")))
        .navigationTitle("New Session")
    }
}
