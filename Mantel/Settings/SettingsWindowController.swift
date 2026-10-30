import AppKit
import MKCommands
import SwiftUI

/// The page Settings is on, and what to do when the person picks another.
@Observable
final class SettingsModel {
    private(set) var selection: SettingsPage
    private let didSelect: (SettingsPage) -> Void

    init(selection: SettingsPage, didSelect: @escaping (SettingsPage) -> Void) {
        self.selection = selection
        self.didSelect = didSelect
    }

    func select(_ page: SettingsPage) {
        guard page != selection else { return }
        selection = page
        didSelect(page)
    }
}

/// The Settings window. While it is open Mantel is an ordinary app, with a Dock icon and a place in ⌘-Tab, and it comes to the front
/// through `ActivationPolicyOwner`; closing it (the last window to close) makes Mantel a menu bar app again. Closing it also ends what
/// its panes were doing (their polling): the content is built again when it is shown.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: SettingsModel
    private let content: DroppableContent
    private let activation: ActivationPolicyOwner
    /// Told when the window is shown and when it is put away: the menu bar is read more often while it is open.
    private let visibilityChanged: (Bool) -> Void

    init(coordinator: AppCoordinator) {
        activation = coordinator.activation
        visibilityChanged = { [weak coordinator] in coordinator?.setSettingsOpen($0) }
        let model = SettingsModel(selection: coordinator.lastSettingsPage,
                                  didSelect: { [weak coordinator] in coordinator?.rememberSettingsPage($0) })
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

    /// Shows the window on `page`, or on the page it was on, and brings it to the front: Mantel becomes an ordinary app, and then (after
    /// the menu the request may have come from has finished) becomes active and has the window key (`WindowShowing`).
    func show(page: SettingsPage?) {
        content.restore()
        if let page { model.select(page) }
        if let window { activation.show(window, as: .settings) }
        visibilityChanged(true)
    }

    /// Whether the window is open on the About page, where a check asked for from Settings answers.
    var isShowingAbout: Bool {
        window?.isVisible == true && model.selection == .about
    }

    func windowWillClose(_ notification: Notification) {
        content.drop()
        visibilityChanged(false)
        activation.windowClosed(.settings)
    }
}
