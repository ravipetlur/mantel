import AppKit
import SwiftUI

/// The pane Settings is on, and what to do when the person picks another.
@Observable
final class SettingsModel {
    private(set) var selection: SettingsPane
    private let didSelect: (SettingsPane) -> Void

    init(selection: SettingsPane, didSelect: @escaping (SettingsPane) -> Void) {
        self.selection = selection
        self.didSelect = didSelect
    }

    func select(_ pane: SettingsPane) {
        guard pane != selection else { return }
        selection = pane
        didSelect(pane)
    }
}

/// The Settings window. It isn't a document window, so closing it leaves the app's activation policy alone. Closing it
/// also ends what its panes were doing (their polling): the content is built again when it is shown.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: SettingsModel
    private let content: DroppableContent

    init(coordinator: AppCoordinator) {
        let model = SettingsModel(selection: coordinator.lastSettingsPane,
                                  didSelect: { [weak coordinator] in coordinator?.rememberSettingsPane($0) })
        self.model = model
        // The coordinator owns this controller, so the content doesn't hold it.
        content = DroppableContent { [unowned coordinator] in AnyView(SettingsView(model: model, coordinator: coordinator)) }
        let window = NSWindow(contentViewController: content.controller)
        window.title = "Mantel Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.setContentSize(NSSize(width: 720, height: 520))
        window.isReleasedWhenClosed = false
        window.center()
        // Where the person left it, once there is one: this takes the saved frame over the one set above.
        window.setFrameAutosaveName("MantelSettings")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the window on `pane`, or on the pane it was on, and brings the app forward.
    func show(pane: SettingsPane?) {
        content.restore()
        if let pane { model.select(pane) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        content.drop()
    }
}
