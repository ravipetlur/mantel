import AppKit

/// Mantel's • in the menu bar, and its menu. Left-click and right-click both open the menu; a later version gives the
/// left click its reveal behaviour.
final class StatusItemController: NSObject {
    /// What the system keeps this item's place in the menu bar under.
    static let autosaveName = "mantel.dot.hidden"

    private let statusItem: NSStatusItem
    private let openSettings: () -> Void
    private let openDiagnostics: () -> Void

    init(openSettings: @escaping () -> Void, openDiagnostics: @escaping () -> Void) {
        self.openSettings = openSettings
        self.openDiagnostics = openDiagnostics
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.autosaveName = Self.autosaveName
        statusItem.button?.image = Self.dot
        statusItem.menu = makeMenu()
    }

    /// A filled 6 pt circle, centred in 18 × 18 pt, drawn as a template so that the menu bar colours it.
    static let dot: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 6, y: 6, width: 6, height: 6)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Mantel"
        return image
    }()

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsChosen), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let diagnostics = NSMenuItem(title: "Diagnostics…", action: #selector(diagnosticsChosen), keyEquivalent: "")
        diagnostics.target = self
        menu.addItem(diagnostics)
        menu.addItem(.separator())
        // No target: the responder chain takes it to the application.
        menu.addItem(NSMenuItem(title: "Quit Mantel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func settingsChosen() { openSettings() }
    @objc private func diagnosticsChosen() { openDiagnostics() }
}
