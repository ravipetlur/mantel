import AppKit
import SwiftUI

/// The welcome window, a step at a time. It is `OnboardingView.size` and can't be resized, by the person or by what a step
/// shows. Closing it ends what its steps were doing (their polling).
///
/// While it is open Mantel is an ordinary app, with a Dock icon and a place in ⌘-Tab, and it comes to the front through
/// `ActivationPolicyOwner`, as Settings does.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let content: DroppableContent
    private let activation: ActivationPolicyOwner

    /// `finish` is called when the person presses Done.
    init(activation: ActivationPolicyOwner, finish: @escaping () -> Void) {
        self.activation = activation
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
        if let window { activation.show(window, as: .onboarding) }
    }

    func windowWillClose(_ notification: Notification) {
        content.drop()
        activation.windowClosed(.onboarding)
    }
}
