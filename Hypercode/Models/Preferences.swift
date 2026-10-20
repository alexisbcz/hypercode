import AppKit
import HighlightSwift
import SwiftUI

/// Every user preference, by its UserDefaults key, so views can share one `@AppStorage` spelling.
enum Pref {
    static let theme = "appearance.theme"
    static let accent = "appearance.accent"
    static let textSize = "appearance.textSize"
    static let codeTheme = "appearance.codeTheme"
    static let bubbleStyle = "appearance.bubbleStyle"
    static let density = "appearance.density"
    static let readingWidth = "appearance.readingWidth"
    static let sidebarSessions = "appearance.sidebarSessions"
    static let sidebarDates = "appearance.sidebarDates"
    static let showThinking = "conversation.showThinking"
    static let expandThinking = "conversation.expandThinking"
    static let showTools = "conversation.showTools"
    static let expandTools = "conversation.expandTools"
    static let dictationLocale = "dictation.locale"

    static let defaultTextSize: Double = 13

    /// Back to how the app looks out of the box.
    static func resetAppearance() {
        for key in [theme, accent, textSize, codeTheme, bubbleStyle, density, readingWidth, sidebarSessions, sidebarDates] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

enum Theme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The accent swatches macOS itself offers, plus following the system's choice.
enum AccentChoice: String, CaseIterable, Identifiable {
    case system, blue, purple, pink, red, orange, yellow, green, graphite
    var id: String { rawValue }
    var label: String { self == .system ? "System" : rawValue.capitalized }

    /// Nil follows the accent color set in System Settings.
    var color: Color? {
        switch self {
        case .system: nil
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .graphite: .gray
        }
    }
}

enum BubbleStyle: String, CaseIterable, Identifiable {
    case gray, tinted, plain
    var id: String { rawValue }
    var label: String {
        switch self {
        case .gray: "Bubble"
        case .tinted: "Tinted"
        case .plain: "Plain"
        }
    }
}

enum Density: String, CaseIterable, Identifiable {
    case compact, cozy, spacious
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// Scales the gaps between messages.
    var factor: CGFloat {
        switch self {
        case .compact: 0.55
        case .cozy: 1
        case .spacious: 1.45
        }
    }
}

enum ReadingWidth: String, CaseIterable, Identifiable {
    case narrow, standard, wide, full
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var maxWidth: CGFloat {
        switch self {
        case .narrow: 620
        case .standard: 760
        case .wide: 980
        case .full: .infinity
        }
    }
}

extension ShapeStyle where Self == Color {
    /// The conversation's page: white in light mode, near-black in dark mode, so it stands apart from the
    /// gray sidebar in both (the default window gray made the dark transcript blend into the sidebar).
    static var transcriptBackground: Color { Color(nsColor: .textBackgroundColor) }
}

extension EnvironmentValues {
    /// The transcript's body size; headings, code and captions scale from it.
    @Entry var textSize: CGFloat = Pref.defaultTextSize
}

/// Applies the chosen theme to the whole app (windows, menus, the menu-bar popover) and the accent as tint.
struct AppAppearance: ViewModifier {
    @AppStorage(Pref.theme) private var theme = Theme.system
    @AppStorage(Pref.accent) private var accent = AccentChoice.system

    func body(content: Content) -> some View {
        content
            .tint(accent.color)
            .onChange(of: theme, initial: true) { NSApp.appearance = theme.appearance }
    }
}

/// The transcript's type and spacing settings, shared by sessions and the settings preview.
struct TranscriptStyle: ViewModifier {
    @AppStorage(Pref.textSize) private var textSize = Pref.defaultTextSize

    func body(content: Content) -> some View {
        content
            .font(.system(size: textSize))
            .environment(\.textSize, textSize)
    }
}
