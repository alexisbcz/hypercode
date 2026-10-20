import SwiftUI

@main
struct HypercodeApp: App {
    @State private var store = Store()
    @State private var usage = UsageMonitor()

    var body: some Scene {
        Window("Hypercode", id: "main") {
            ContentView()
                .environment(store)
                .modifier(AppAppearance())
                .frame(minWidth: 760, minHeight: 480)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { store.newSession() }
                    .keyboardShortcut("n")
                Button("Open Project…") { store.openProject() }
                    .keyboardShortcut("o")
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
        }
        .menuBarExtraStyle(.window)
    }
}
