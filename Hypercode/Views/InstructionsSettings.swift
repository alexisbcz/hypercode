import SwiftUI

/// Your prompts, as files: CLAUDE.md memory, slash commands, agents, skills and output styles, yours or a project's.
struct InstructionsSettings: View {
    @Environment(Store.self) private var store
    /// Nil for yours, else a project's ID.
    @State private var projectID: String?
    @State private var files: [InstructionFile] = []
    @State private var selection: InstructionFile?
    @State private var creating: InstructionFile.Kind?
    @State private var newName = ""
    @State private var problem: String?

    private var scope: InstructionScope {
        if let project = store.projects.first(where: { $0.id == projectID }) { return .project(project) }
        return .user
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
            Divider()
            Group {
                if let selection {
                    InstructionEditor(file: selection, onSave: saved, onDelete: delete)
                        .id(selection.url)
                } else {
                    ContentUnavailableView("No File Selected", systemImage: "doc.text", description: Text("Pick a file, or add a command, agent, skill or output style with +."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 900, height: 620)
        .task(id: scope) { reload(keeping: nil) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload(keeping: selection) }
        .alert("New \(creating?.noun ?? "File")", isPresented: Binding(get: { creating != nil }, set: { if !$0 { creating = nil } })) {
            TextField("Name", text: $newName)
            Button("Create", action: create)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(creating?.explanation ?? "")
        }
        .alert("Couldn't Do That", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") {}
        } message: {
            Text(problem ?? "")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("Instructions for", selection: $projectID) {
                Text("You (All Projects)").tag(String?.none)
                if !store.projects.isEmpty {
                    Divider()
                    ForEach(store.projects) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            .labelsHidden()
            .padding(10)

            List(selection: $selection) {
                ForEach(InstructionFile.Kind.allCases, id: \.self) { kind in
                    let group = files.filter { $0.kind == kind }
                    if !group.isEmpty || kind != .memory {
                        Section(kind.title) {
                            ForEach(group) { file in
                                row(file).tag(file)
                            }
                            if group.isEmpty {
                                Text("None yet")
                                    .foregroundStyle(.tertiary)
                                    .selectionDisabled()
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .tint(.accentColor)

            Divider()
            HStack {
                Menu {
                    ForEach(InstructionFile.Kind.allCases.filter { $0 != .memory }, id: \.self) { kind in
                        Button("New \(kind.noun)…", systemImage: kind.symbol) {
                            newName = ""
                            creating = kind
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a command, agent, skill or output style")
                Spacer()
                Button("Show in Finder", systemImage: "folder") {
                    let folder = scope.claudeFolder
                    NSWorkspace.shared.open(FileManager.default.fileExists(atPath: folder.path) ? folder : folder.deletingLastPathComponent())
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Show the .claude folder in Finder")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private func row(_ file: InstructionFile) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                if !file.detail.isEmpty || !file.exists {
                    Text(file.exists ? file.detail : "\(file.detail) · not created yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: file.kind.symbol)
        }
    }

    private func reload(keeping kept: InstructionFile?) {
        files = InstructionFile.all(in: scope)
        selection = kept.flatMap { kept in files.first { $0.url == kept.url } } ?? files.first
    }

    private func create() {
        guard let kind = creating else { return }
        do {
            let file = try InstructionFile.create(kind, named: newName, in: scope)
            reload(keeping: file)
            store.refreshCommands()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The composer's / menu shows commands and skills by their descriptions, so those changes need a fresh list.
    private func saved(_ file: InstructionFile) {
        if file.kind == .command || file.kind == .skill { store.refreshCommands() }
        if !file.exists || file.kind == .memory { reload(keeping: file) }
    }

    private func delete(_ file: InstructionFile) {
        do {
            try file.trash()
            reload(keeping: nil)
            store.refreshCommands()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// One instruction file's text, saved with ⌘S or the Save button; unsaved edits are flagged, not lost silently.
private struct InstructionEditor: View {
    let file: InstructionFile
    let onSave: (InstructionFile) -> Void
    let onDelete: (InstructionFile) -> Void
    @State private var text = ""
    @State private var saved = ""
    @State private var confirmingDelete = false
    @State private var problem: String?

    private var isDirty: Bool { text != saved }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.headline)
                    Text(file.kind.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if file.isRemovable {
                    Button("Move to Trash", systemImage: "trash") { confirmingDelete = true }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Move to Trash")
                }
                Button("Revert", action: load)
                    .disabled(!isDirty)
                Button("Save", action: save)
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty)
            }
            .padding(16)

            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(file.exists ? "Empty. Start typing…" : "Start typing, then Save to create the file.")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 17)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Text(file.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                } else if isDirty {
                    Text("Edited").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear(perform: load)
        .confirmationDialog("Move “\(file.name)” to the Trash?", isPresented: $confirmingDelete) {
            Button("Move to Trash", role: .destructive) { onDelete(file) }
        } message: {
            Text("You can put it back from the Trash.")
        }
    }

    private func load() {
        let contents = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
        text = contents
        saved = contents
        problem = nil
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file.url, options: .atomic)
            saved = text
            problem = nil
            onSave(file)
        } catch {
            problem = error.localizedDescription
        }
    }
}
