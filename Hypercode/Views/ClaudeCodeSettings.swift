import SwiftUI

/// Claude Code's own settings.json, as forms: the model, permissions, environment, attribution, hooks.
/// Anything without a form is still one click away in the JSON editor.
struct ClaudeCodeSettings: View {
    @Environment(Store.self) private var store
    @AppStorage("settings.claude.scope") private var scope = SettingsScope.user
    @State private var projectID: String?
    @State private var file: SettingsFile?
    @State private var editing: JSONEditing?

    private var project: Project? {
        store.projects.first { $0.id == projectID } ?? store.selectedSession?.project ?? store.projects.first
    }

    private var url: URL? { scope.url(in: project) }

    var body: some View {
        Form {
            Section {
                Picker("Settings for", selection: $scope) {
                    ForEach(SettingsScope.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if scope != .user {
                    Picker("Project", selection: Binding(get: { project?.id }, set: { projectID = $0 })) {
                        ForEach(store.projects) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(scope.summary)
                    if let url {
                        HStack(spacing: 6) {
                            Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            if file?.exists == true {
                                Button("Show in Finder", systemImage: "arrow.forward.circle.fill") {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .foregroundStyle(.secondary)
            }

            if let file {
                if let problem = file.problem {
                    Section {
                        Label("This file isn't valid JSON, so nothing here can change it until it's fixed. \(problem)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Fix in the JSON Editor…") { editing = JSONEditing(title: url?.lastPathComponent ?? "settings.json", path: []) }
                    }
                } else {
                    GeneralSection(file: file, models: store.models)
                    PermissionsSection(file: file)
                    EnvironmentSection(file: file)
                    AttributionSection(file: file)
                    Section {
                        LabeledContent("Hooks") {
                            Button(hookSummary(file)) { editing = JSONEditing(title: "Hooks", path: ["hooks"]) }
                        }
                        LabeledContent("Everything else") {
                            Button("Edit settings.json…") { editing = JSONEditing(title: url?.lastPathComponent ?? "settings.json", path: []) }
                        }
                    } header: {
                        Text("Advanced")
                    } footer: {
                        Text("Hooks run your own commands when Claude uses a tool, finishes a reply, and more. The JSON editor reaches every setting Claude Code has, including ones without a control here.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    Text("Open a project to edit its settings.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 720)
        .task(id: url) { file = url.map(SettingsFile.init) }
        // Claude Code may have changed the file meanwhile ("always allow" adds a rule, say).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in file?.reload() }
        .sheet(item: $editing) { editing in
            if let file { JSONEditor(file: file, editing: editing) }
        }
    }

    private func hookSummary(_ file: SettingsFile) -> String {
        let events = file["hooks"]?.pairs?.count ?? 0
        return events == 0 ? "Add Hooks…" : events == 1 ? "1 Event…" : "\(events) Events…"
    }
}

struct JSONEditing: Identifiable {
    let title: String
    let path: [String]
    var id: String { path.joined(separator: ".") }
}

// MARK: - General

private struct GeneralSection: View {
    let file: SettingsFile
    let models: [ModelOption]

    /// Claude Code's own names for its permission modes, in the order its Shift-Tab cycles them.
    private static let modes: [(value: String, label: String)] = [
        ("default", "Ask Before Acting"),
        ("acceptEdits", "Accept Edits"),
        ("plan", "Plan"),
        ("auto", "Auto"),
        ("bypassPermissions", "Bypass Permissions"),
    ]

    var body: some View {
        Section {
            ChoicePicker(
                "Model", file: file, path: ["model"],
                choices: models.filter { $0.value != "default" }.map { ($0.value, $0.displayName) }
            )
            ChoicePicker("Default permission mode", file: file, path: ["permissions", "defaultMode"], choices: Self.modes)
            ChoicePicker("Output style", file: file, path: ["outputStyle"], choices: outputStyles)
            FlagPicker("Thinking on by default", file: file, path: ["alwaysThinkingEnabled"])
            NumberField("Keep transcripts for", unit: "days", placeholder: "30", file: file, path: ["cleanupPeriodDays"])
        } header: {
            Text("General")
        } footer: {
            Text("“Default” leaves a setting out of this file, so the next file down decides, or Claude Code's own default.")
                .foregroundStyle(.secondary)
        }
    }

    /// The built-in styles and any you've written.
    private var outputStyles: [(value: String, label: String)] {
        let builtIn = [("default", "Standard"), ("Explanatory", "Explanatory"), ("Learning", "Learning")]
        let custom = InstructionFile.all(in: .user).filter { $0.kind == .outputStyle }.map { ($0.name, $0.name) }
        return builtIn + custom
    }
}

// MARK: - Permissions

private struct PermissionsSection: View {
    let file: SettingsFile

    var body: some View {
        Section {
            RuleList(title: "Allow", symbol: "checkmark.circle.fill", color: .green, file: file, path: ["permissions", "allow"],
                     prompt: "Bash(npm run test:*)")
            RuleList(title: "Ask", symbol: "questionmark.circle.fill", color: .orange, file: file, path: ["permissions", "ask"],
                     prompt: "Bash(git push:*)")
            RuleList(title: "Deny", symbol: "xmark.circle.fill", color: .red, file: file, path: ["permissions", "deny"],
                     prompt: "Read(./.env)")
        } header: {
            Text("Permission Rules")
        } footer: {
            Text("A rule names a tool, optionally with what it applies to: `WebFetch`, `Bash(npm run build)`, `Edit(src/**)`, `mcp__github`. Deny wins over Ask, and Ask over Allow.")
                .foregroundStyle(.secondary)
        }

        Section {
            RuleList(title: "Extra folders", symbol: "folder.fill", color: .blue, file: file, path: ["permissions", "additionalDirectories"],
                     prompt: "~/Work/shared", choosesFolders: true)
            Toggle("Turn off Bypass Permissions", isOn: Binding(
                get: { file["permissions", "disableBypassPermissionsMode"]?.string == "disable" },
                set: { file.set($0 ? .string("disable") : nil, at: "permissions", "disableBypassPermissionsMode") }
            ))
            FlagPicker("Skip the Bypass Permissions warning", file: file, path: ["skipDangerousModePermissionPrompt"])
        } header: {
            Text("Access")
        } footer: {
            Text("Claude can read and edit the project's folder; extra folders join it. Turning off Bypass Permissions removes that mode, even when asked for on the command line.")
                .foregroundStyle(.secondary)
        }
    }
}

/// A list of strings in the file (rules, folders) with remove buttons and a field to add one.
private struct RuleList: View {
    let title: String
    let symbol: String
    let color: Color
    let file: SettingsFile
    let path: [String]
    let prompt: String
    var choosesFolders = false
    @State private var draft = ""

    private var items: [String] { file.root.value(at: path)?.strings ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(color)
                }
                Spacer()
                Text(items.isEmpty ? "None" : "\(items.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack {
                    Text(item)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Remove", systemImage: "minus.circle") { save(items.enumerated().filter { $0.offset != index }.map(\.element)) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 26)
            }
            HStack {
                TextField(title, text: $draft, prompt: Text(prompt))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit(add)
                if choosesFolders {
                    Button("Choose…", action: chooseFolder)
                }
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.leading, 26)
        }
        .padding(.vertical, 2)
    }

    private func add() {
        let rule = draft.trimmingCharacters(in: .whitespaces)
        guard !rule.isEmpty else { return }
        if !items.contains(rule) { save(items + [rule]) }
        draft = ""
    }

    private func save(_ list: [String]) {
        file.set(list.isEmpty ? nil : .array(list.map(OrderedJSON.string)), at: path)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        save(items + added.filter { !items.contains($0) })
    }
}

// MARK: - Environment

private struct EnvironmentSection: View {
    let file: SettingsFile
    @State private var newKey = ""
    @State private var newValue = ""

    private var variables: [(key: String, value: OrderedJSON)] { file["env"]?.pairs ?? [] }

    var body: some View {
        Section {
            ForEach(variables, id: \.key) { variable in
                HStack {
                    Text(variable.key)
                        .font(.body.monospaced())
                        .frame(maxWidth: 260, alignment: .leading)
                        .textSelection(.enabled)
                    CommitField(
                        value: variable.value.string ?? variable.value.formatted(),
                        prompt: "Value",
                        commit: { file.set(.string($0), at: "env", variable.key) }
                    )
                    .font(.body.monospaced())
                    Button("Remove", systemImage: "minus.circle") { file.set(nil, at: "env", variable.key) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("Name", text: $newKey, prompt: Text("NAME"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                TextField("Value", text: $newValue, prompt: Text("value"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .font(.body.monospaced())
        } header: {
            Text("Environment Variables")
        } footer: {
            Text("Set for Claude Code and every command it runs, like `CLAUDE_CODE_MAX_OUTPUT_TOKENS` or `BASH_DEFAULT_TIMEOUT_MS`.")
                .foregroundStyle(.secondary)
        }
    }

    private func add() {
        let key = newKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        file.set(.string(newValue), at: "env", key)
        newKey = ""
        newValue = ""
    }
}

// MARK: - Attribution

private struct AttributionSection: View {
    let file: SettingsFile

    var body: some View {
        Section {
            AttributionRow(title: "Commits", file: file, key: "commit")
            AttributionRow(title: "Pull requests", file: file, key: "pr")
        } header: {
            Text("Attribution")
        } footer: {
            Text("What Claude adds to the commits and pull requests it writes. By default, a “Generated with Claude Code” line and a Co-Authored-By trailer.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct AttributionRow: View {
    enum Choice: Hashable { case standard, none, custom }

    let title: String
    let file: SettingsFile
    let key: String

    private var value: String? { file["attribution", key]?.string }
    private var choice: Choice { value == nil ? .standard : value!.isEmpty ? .none : .custom }

    var body: some View {
        Picker(title, selection: Binding(get: { choice }, set: { pick($0) })) {
            Text("Default").tag(Choice.standard)
            Text("None").tag(Choice.none)
            Text("Custom").tag(Choice.custom)
        }
        if choice == .custom {
            CommitField(value: value ?? "", prompt: "Text to add", axis: .vertical) {
                file.set(.string($0.isEmpty ? " " : $0), at: "attribution", key)
            }
            .labelsHidden()
        }
    }

    private func pick(_ choice: Choice) {
        switch choice {
        case .standard: file.set(nil, at: "attribution", key)
        case .none: file.set(.string(""), at: "attribution", key)
        case .custom: file.set(.string("Co-Authored-By: Claude <noreply@anthropic.com>"), at: "attribution", key)
        }
    }
}

// MARK: - Controls

/// A menu of known values, plus "Default" (the key left out) and whatever the file holds if it's none of them.
private struct ChoicePicker: View {
    let title: String
    let file: SettingsFile
    let path: [String]
    let choices: [(value: String, label: String)]

    init(_ title: String, file: SettingsFile, path: [String], choices: [(value: String, label: String)]) {
        self.title = title
        self.file = file
        self.path = path
        self.choices = choices
    }

    var body: some View {
        let current = file.root.value(at: path)?.string
        Picker(title, selection: Binding(get: { current }, set: { file.set($0.map(OrderedJSON.string), at: path) })) {
            Text("Default").tag(String?.none)
            Divider()
            ForEach(choices, id: \.value) { Text($0.label).tag(Optional($0.value)) }
            if let current, !choices.contains(where: { $0.value == current }) {
                Text(current).tag(Optional(current))
            }
        }
    }
}

/// On, Off, or Default (left out): a Toggle can't say "whatever Claude Code does".
private struct FlagPicker: View {
    let title: String
    let file: SettingsFile
    let path: [String]

    init(_ title: String, file: SettingsFile, path: [String]) {
        self.title = title
        self.file = file
        self.path = path
    }

    var body: some View {
        Picker(title, selection: Binding(get: { file.root.value(at: path)?.bool }, set: { file.set($0.map(OrderedJSON.bool), at: path) })) {
            Text("Default").tag(Bool?.none)
            Divider()
            Text("On").tag(Optional(true))
            Text("Off").tag(Optional(false))
        }
    }
}

private struct NumberField: View {
    let title: String
    let unit: String
    let placeholder: String
    let file: SettingsFile
    let path: [String]

    init(_ title: String, unit: String, placeholder: String, file: SettingsFile, path: [String]) {
        self.title = title
        self.unit = unit
        self.placeholder = placeholder
        self.file = file
        self.path = path
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                CommitField(value: file.root.value(at: path)?.int.map(String.init) ?? "", prompt: placeholder) { text in
                    file.set(Int(text.trimmingCharacters(in: .whitespaces)).map { .number(String($0)) }, at: path)
                }
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}

/// A text field that saves when you press Return or leave it, not on every keystroke, and picks up
/// changes made to the file meanwhile.
private struct CommitField: View {
    let value: String
    let prompt: String
    var axis: Axis = .horizontal
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(prompt, text: $text, prompt: Text(prompt), axis: axis)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit { save() }
            .onChange(of: isFocused) { if !isFocused { save() } }
            .onChange(of: value, initial: true) { if !isFocused { text = value } }
    }

    private func save() {
        if text != value { commit(text) }
    }
}

// MARK: - JSON editor

/// Edits a key of the file (or the whole file) as JSON, checking it parses before saving.
private struct JSONEditor: View {
    let file: SettingsFile
    let editing: JSONEditing
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing.title).font(.headline)
            if editing.path == ["hooks"] {
                Text("Each event (`PreToolUse`, `PostToolUse`, `Stop`, `UserPromptSubmit`…) lists matchers and the commands to run.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .onChange(of: text) { problem = nil }
            HStack {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .onAppear(perform: load)
    }

    private func load() {
        file.reload()
        if editing.path.isEmpty {
            text = file.text
        } else {
            text = file.root.value(at: editing.path)?.formatted() ?? "{\n  \n}"
        }
    }

    private func save() {
        do {
            if editing.path.isEmpty {
                try file.replace(with: text)
            } else {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = try OrderedJSON.parse(trimmed.isEmpty ? "{}" : trimmed)
                let isEmpty = value.pairs?.isEmpty == true || value.array?.isEmpty == true
                file.set(isEmpty ? nil : value, at: editing.path)
            }
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
