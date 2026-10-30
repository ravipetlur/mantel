import AppKit
import MKUpdate
import SwiftUI

/// The update window: a small, fixed-size window that offers a release and shows its install. Made once and kept; it
/// follows the update center's flow.
final class UpdateWindowController: NSWindowController, NSWindowDelegate {
    private unowned let center: UpdateCenter
    private let activation: ActivationPolicyOwner
    /// Whether Return may install: only once this window has been key for a moment (`DefaultActionArming`).
    private var arming = DefaultActionArming()
    private var armingTask: Task<Void, Never>?

    /// The window's size is fixed: its content has one size in every state, and the window can't be resized.
    static let contentSize = NSSize(width: 480, height: 420)

    init(center: UpdateCenter, activation: ActivationPolicyOwner) {
        self.center = center
        self.activation = activation
        let hosting = NSHostingController(rootView: UpdateView(center: center))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(Self.contentSize)
        window.setAccessibilityLabel("Mantel update")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var isOpen: Bool { window?.isVisible ?? false }

    /// Shows the window on `release`, in front, the way Mantel's windows are shown (`ActivationPolicyOwner`). `activating` is for an
    /// offer the person asked for: the window becomes key and Mantel active. A background offer (`false`) is only ordered in
    /// front, with neither: the person may be typing in another app, and the window must not take that app's keys. Return then
    /// does nothing here until the window has been key for a moment, however it came to be key.
    func show(for release: ReleaseInfo, activating: Bool) {
        guard let window else { return }
        window.title = "Mantel \(release.version) is available"
        if !window.isVisible { window.center() }
        if activating {
            activation.show(window, as: .update)
        } else {
            activation.showWithoutActivating(window, as: .update)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        armingTask?.cancel()
        // The first look starts the wait. The next comes when it is over, and the window is looked at again until Return
        // is armed or the window stops being key, so one early look can't leave Return unarmed for good.
        refreshArming()
        let delay = arming.delay
        armingTask = Task { [weak self] in
            var wait = delay
            while let self, !Task.isCancelled, window?.isKeyWindow == true, !center.defaultActionArmed {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                refreshArming()
                wait = Self.relookInterval
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        disarm()
    }

    func windowWillClose(_ notification: Notification) {
        disarm()
        activation.windowClosed(.update)
        center.windowDidClose()
    }

    /// How soon the window is looked at again when the first wait left Return unarmed.
    private static let relookInterval: TimeInterval = 0.25

    /// The window as it is now, on the continuous clock: a change of the wall clock can't affect the wait.
    private func refreshArming() {
        center.setDefaultActionArmed(arming.observe(isKey: window?.isKeyWindow ?? false, at: .now))
    }

    private func disarm() {
        armingTask?.cancel()
        armingTask = nil
        arming.restart()
        center.setDefaultActionArmed(false)
    }
}
