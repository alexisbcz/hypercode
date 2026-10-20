import HighlightSwift
import Speech
import SwiftUI

/// The Settings window (⌘,): native tabs and grouped forms, like System Settings.
struct SettingsView: View {
    /// Reopens on the tab you used last.
    @AppStorage("settings.tab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") {
                GeneralSettings()
            }
            Tab("Appearance", systemImage: "paintpalette", value: "appearance") {
                AppearanceSettings()
            }
        }
        .modifier(AppAppearance())
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(Store.self) private var store
    @AppStorage(Pref.showThinking) private var showThinking = true
    @AppStorage(Pref.expandThinking) private var expandThinking = false
    @AppStorage(Pref.showTools) private var showTools = true
    @AppStorage(Pref.expandTools) private var expandTools = false
    @AppStorage(Pref.dictationLocale) private var dictationLocale = ""

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Picker("Permission mode", selection: $store.config.mode) {
                    ForEach(PermissionMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Model", selection: Binding(get: { store.config.model }, set: { store.selectModel($0) })) {
                    ForEach(store.models) { Text($0.displayName).tag($0.value) }
                }
                if !store.efforts.isEmpty {
                    Picker("Effort", selection: $store.config.effort) {
                        ForEach(store.efforts) { Text($0.label).tag(Optional($0)) }
                    }
                }
            } header: {
                Text("Claude")
            } footer: {
                Text("The same choices as the menus under the composer; they apply to the next message you send.")
                    .foregroundStyle(.secondary)
            }

            Section("Conversation") {
                Toggle("Show thinking", isOn: $showThinking)
                Toggle("Expand thinking by default", isOn: $expandThinking)
                    .disabled(!showThinking)
                Toggle("Show tool calls", isOn: $showTools)
                Toggle("Expand tool calls by default", isOn: $expandTools)
                    .disabled(!showTools)
            }

            Section {
                Picker("Language", selection: $dictationLocale) {
                    Text("System Default").tag("")
                    Divider()
                    ForEach(Self.dictationLocales, id: \.identifier) { locale in
                        Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                            .tag(locale.identifier)
                    }
                }
            } header: {
                Text("Dictation")
            } footer: {
                Text("Press ⇧⌘D in the composer to dictate. Languages your Mac supports offline are recognized on-device.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static let dictationLocales = SFSpeechRecognizer.supportedLocales().sorted {
        (Locale.current.localizedString(forIdentifier: $0.identifier) ?? "") < (Locale.current.localizedString(forIdentifier: $1.identifier) ?? "")
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @AppStorage(Pref.theme) private var theme = Theme.system
    @AppStorage(Pref.accent) private var accent = AccentChoice.system
    @AppStorage(Pref.textSize) private var textSize = Pref.defaultTextSize
    @AppStorage(Pref.codeTheme) private var codeTheme = HighlightTheme.xcode
    @AppStorage(Pref.bubbleStyle) private var bubbleStyle = BubbleStyle.gray
    @AppStorage(Pref.density) private var density = Density.cozy
    @AppStorage(Pref.readingWidth) private var readingWidth = ReadingWidth.standard
    @AppStorage(Pref.sidebarSessions) private var sidebarSessions = 5
    @AppStorage(Pref.sidebarDates) private var sidebarDates = true

    var body: some View {
        Form {
            Section {
                TranscriptPreview()
                    .listRowInsets(EdgeInsets())
            }

            Section("Theme") {
                HStack(spacing: 0) {
                    ForEach(Theme.allCases) { option in
                        ThemeOption(theme: option, isSelected: theme == option) {
                            withAnimation(.snappy) { theme = option }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 6)

                LabeledContent("Accent color") {
                    HStack(spacing: 9) {
                        ForEach(AccentChoice.allCases) { option in
                            AccentSwatch(choice: option, isSelected: accent == option) {
                                withAnimation(.snappy) { accent = option }
                            }
                        }
                    }
                }
            }

            Section("Text") {
                LabeledContent("Text size") {
                    HStack(spacing: 10) {
                        Image(systemName: "textformat.size.smaller")
                            .foregroundStyle(.secondary)
                        Slider(value: $textSize, in: 11...18, step: 1)
                            .frame(width: 180)
                        Image(systemName: "textformat.size.larger")
                            .foregroundStyle(.secondary)
                        Text("\(Int(textSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                Picker("Code colors", selection: $codeTheme) {
                    ForEach(HighlightTheme.allCases) { Text($0.rawValue).tag($0) }
                }
            }

            Section("Messages") {
                Picker("Your messages", selection: $bubbleStyle) {
                    ForEach(BubbleStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Spacing", selection: $density) {
                    ForEach(Density.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Reading width", selection: $readingWidth) {
                    ForEach(ReadingWidth.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Sidebar") {
                Picker("Sessions per project", selection: $sidebarSessions) {
                    ForEach([3, 5, 10, 20], id: \.self) { Text("\($0)").tag($0) }
                    Divider()
                    Text("All").tag(0)
                }
                Toggle("Show when each session was last active", isOn: $sidebarDates)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        withAnimation(.snappy) { Pref.resetAppearance() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 720)
    }
}

/// A short sample conversation, drawn by the real transcript views so every setting shows as it will look.
private struct TranscriptPreview: View {
    private static let entries: [Entry] = [
        Entry(id: "u", kind: .user, text: "Can you add a theme picker to the settings screen?"),
        Entry(id: "t1", kind: .tool, tool: ToolCall(
            name: "Read", input: .object(["file_path": .string("Sources/Settings/SettingsView.swift")]), result: "…"
        )),
        Entry(id: "t2", kind: .tool, tool: ToolCall(
            name: "Edit", input: .object(["file_path": .string("Sources/Settings/SettingsView.swift")]), result: "…"
        )),
        Entry(id: "a", kind: .assistant, text: """
        Done. The picker is saved with **`@AppStorage`**, so it sticks between launches:

        ```swift
        @AppStorage("theme") private var theme = Theme.system
        ```
        """),
    ]

    var body: some View {
        TranscriptList(entries: Self.entries)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: 290, alignment: .top)
            .clipped()
            .background(.background)
            .allowsHitTesting(false)
            .accessibilityLabel("Preview")
    }
}

/// A miniature window in light, dark, or half of each, like System Settings' appearance picker.
private struct ThemeOption: View {
    let theme: Theme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                thumbnail
                    .frame(width: 112, height: 72)
                    .clipShape(.rect(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator))
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.tint, lineWidth: 3)
                            .opacity(isSelected ? 1 : 0)
                    }
                Text(theme.label)
                    .font(.callout)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch theme {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            MiniWindow(dark: false)
                .overlay(alignment: .trailing) {
                    MiniWindow(dark: true)
                        .mask(alignment: .trailing) { Rectangle().frame(width: 56) }
                }
        }
    }
}

/// Sidebar, a reply, your bubble, and the composer, in a few rounded strokes.
private struct MiniWindow: View {
    let dark: Bool

    var body: some View {
        let background = dark ? Color(white: 0.13) : Color(white: 0.98)
        let sidebar = dark ? Color(white: 0.2) : Color(white: 0.9)
        let ink = dark ? Color.white.opacity(0.28) : Color.black.opacity(0.16)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2.5) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 4, height: 4) }
                }
                .padding(.bottom, 4)
                Capsule().fill(.tint).frame(width: 22, height: 4)
                Capsule().fill(ink).frame(width: 18, height: 3)
                Capsule().fill(ink).frame(width: 20, height: 3)
                Spacer()
            }
            .padding(6)
            .frame(width: 34, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(sidebar)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(.tint.opacity(0.85)).frame(width: 34, height: 7)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Capsule().fill(ink).frame(width: 52, height: 3)
                Capsule().fill(ink).frame(width: 40, height: 3)
                Spacer()
                RoundedRectangle(cornerRadius: 4).fill(sidebar).frame(height: 9)
            }
            .padding(7)
        }
        .background(background)
    }
}

/// One accent color dot; "System" is the multicolor wheel macOS uses for "follow the system".
private struct AccentSwatch: View {
    let choice: AccentChoice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let color = choice.color {
                    Circle().fill(color.gradient)
                } else {
                    Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red], center: .center))
                }
                Circle().strokeBorder(.black.opacity(0.12))
                if isSelected {
                    Circle().fill(.white).frame(width: 7, height: 7)
                        .shadow(color: .black.opacity(0.25), radius: 1)
                }
            }
            .frame(width: 20, height: 20)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(choice.label)
        .accessibilityLabel(choice.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
