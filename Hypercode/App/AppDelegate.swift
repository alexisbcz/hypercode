import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let store = Store()
    private let usage = UsageMonitor()
    private var windowController: MainWindowController?
    private var statusItem: NSStatusItem?
    private var usagePopover: NSPopover?
    private var usageObserver: Observer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        let controller = MainWindowController(store: store)
        windowController = controller
        controller.showWindow(nil)
        installStatusItem()
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    /// The usage item stays in the menu bar, so closing the window doesn't quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func showMainWindow() {
        windowController?.showWindow(nil)
        NSApp.activate()
    }

    // MARK: - Actions

    @objc func newSession(_ sender: Any?) {
        showMainWindow()
        windowController?.newSession()
    }

    @objc func openProject(_ sender: Any?) { store.openProject() }

    @objc func stopSession(_ sender: Any?) { store.selectedSession?.stop() }

    @objc func showCommands(_ sender: Any?) {
        showMainWindow()
        windowController?.composer?.beginCommand()
    }

    @objc func clearSession(_ sender: Any?) {
        store.newSession(in: store.selectedSession?.project)
    }

    @objc func focusComposer(_ sender: Any?) { windowController?.composer?.focus() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(stopSession(_:)): store.selectedSession?.isRunning == true
        case #selector(clearSession(_:)): store.selectedSession != nil
        default: true
        }
    }

    // MARK: - Menus

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }

        submenu("Hypercode", [
            item("About Hypercode", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide Hypercode", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Hypercode", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("File", [
            item("New Session", #selector(newSession(_:)), "n"),
            item("Open Project…", #selector(openProject(_:)), "o"),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("Session", [
            item("Commands…", #selector(showCommands(_:)), "/"),
            item("Clear Context", #selector(clearSession(_:)), "k"),
            item("Stop", #selector(stopSession(_:)), "."),
            .separator(),
            item("Focus Composer", #selector(focusComposer(_:)), "l"),
        ])
        submenu("View", [
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Hypercode", #selector(showMainWindow), "0"))
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window
        submenu("Help", [])
        return main
    }

    // MARK: - Usage in the menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggleUsage)
        statusItem = item
        usageObserver = Observer { [weak self] in
            guard let self else { return }
            statusItem?.button?.image = UsageMenuLabel.glyph(days: usage.days, percent: usage.session?.percent)
        }
    }

    @objc private func toggleUsage() {
        if let popover = usagePopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem?.button else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: UsageMenu(monitor: usage) { [weak self] in
            self?.usagePopover?.performClose(nil)
            self?.showMainWindow()
        })
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        usagePopover = popover
    }
}
