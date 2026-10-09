import AppKit
import SwiftUI

/// The welcome window, a step at a time. It is `OnboardingView.size` and can't be resized, by the person or by what a step
/// shows. Closing it ends what its steps were doing (their polling).
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let content: DroppableContent

    /// `finish` is called when the person presses Done.
    init(finish: @escaping () -> Void) {
        let model = OnboardingModel(finish: finish)
        content = DroppableContent { AnyView(OnboardingView(model: model)) }
        let window = NSWindow(contentViewController: content.controller)
        window.title = "Welcome to Mantel"
        window.styleMask = [.titled, .closable]
        window.setContentSize(OnboardingView.size)
        window.contentMinSize = OnboardingView.size
        window.contentMaxSize = OnboardingView.size
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        content.restore()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        content.drop()
    }
}
