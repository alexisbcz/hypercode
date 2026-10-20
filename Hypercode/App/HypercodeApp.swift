import SwiftUI

@main
struct HypercodeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var usage = UsageMonitor()

    private var store: Store { delegate.store }

    var body: some Scene {
        Window("Hypercode", id: "main") {
            ContentView()
                .environment(store)
                .modifier(AppAppearance())
                .modifier(WindowOpener(delegate: delegate))
                .frame(minWidth: 760, minHeight: 480)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { store.newSession() }
                    .keyboardShortcut("n")
                Button("Open Project…") { store.openProject() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .appSettings) {
                Button("Install ‘hypercode’ Command in PATH") { CommandLineTool.installShowingResult() }
            }
        }

        Settings {
            SettingsView()
                .environment(store)
        }

        MenuBarExtra {
            UsageMenu(monitor: usage)
                .modifier(AppAppearance())
        } label: {
            UsageMenuLabel(monitor: usage)
                .modifier(WindowOpener(delegate: delegate))
        }
        .menuBarExtraStyle(.window)
    }
}

/// Opens folders handed to the app: `hypercode .`, `open -a Hypercode <folder>`, or a folder dropped on the Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here rather than by the App, so folders that arrive at launch have somewhere to go.
    let store = Store()
    /// Brings back the main window, which may have been closed while the menu bar item keeps the app running.
    var showWindow: () -> Void = {}

    func application(_ application: NSApplication, open urls: [URL]) {
        let folders = urls.filter(\.isFileURL).map { url in
            url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                ? url : url.deletingLastPathComponent()
        }
        for folder in folders { store.addProject(folder.standardizedFileURL) }
        showWindow()
        application.activate()
    }
}

/// Hands the delegate a way to open the main window, from views that are on screen whether it's open or not.
private struct WindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let delegate: AppDelegate

    func body(content: Content) -> some View {
        content.onAppear { delegate.showWindow = { openWindow(id: "main") } }
    }
}
