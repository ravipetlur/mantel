import AppKit

/// MantelTestItem: a menu-bar-only app with two status items, for Mantel's probes to hide, show and move, so that they never have to
/// touch the person's own apps. It does nothing else.
///
/// - The items are `mantel.fixture.one` and `mantel.fixture.two` (their autosave names, which is what the menu bar layout
///   keeps their places under), drawn as the symbols `1.circle` and `2.circle`.
/// - Each has a menu with its own name and Quit.
/// - Started with `--single` it has only the first item.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var items: [NSStatusItem] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // macOS 27 can quit an accessory app that has no windows open; the items have to stay.
        ProcessInfo.processInfo.disableAutomaticTermination("MantelTestItem keeps its status items")
        ProcessInfo.processInfo.disableSuddenTermination()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        items = [makeItem(autosaveName: "mantel.fixture.one", symbol: "1.circle", title: "Fixture item one")]
        if !CommandLine.arguments.contains("--single") {
            items.append(makeItem(autosaveName: "mantel.fixture.two", symbol: "2.circle", title: "Fixture item two"))
        }
    }

    private func makeItem(autosaveName: String, symbol: String, title: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = autosaveName
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.button?.setAccessibilityLabel(title)

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = true
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        return item
    }
}
