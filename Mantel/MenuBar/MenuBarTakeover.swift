import AppKit
import MKCore

/// Makes Mantel the active app, with a menu of its own and not much else, so that the menus of the app that was in front come off the
/// menu bar and the room they took is there for the icons that were revealed. (The policy that hides the front app's menus.)
///
/// - **`begin`** remembers the app that is in front (unless that is Mantel), makes Mantel an ordinary app (it has no Dock icon and no
///   menu bar of its own otherwise: its short main menu, the Mantel menu alone, comes with that) and brings it forward. It says whether
///   Mantel did come forward; if not, the caller ends the takeover, which leaves no Dock icon and no menu behind (when no window of
///   Mantel's is open: one that is keeps both).
/// - **`end`** gives the focus back to the app it was taken from. When there is none to give it to, or the person used a window of
///   Mantel's that they have since closed, and Mantel would be left as the active app with no window, Mantel steps back instead
///   (`ActivationPolicyOwner.takeoverEnded`): an app with no Dock icon and no window must not keep the focus.
/// - **It ends by itself when another app comes to the front,** the person having gone elsewhere: the focus isn't taken back then, it
///   is where the person put it.
/// - **The focus isn't taken back from a window of Mantel's that the person used** during the takeover (clicked in, or typed in, or
///   asked for) **and that is still open when it ends**. A window that is only key is not that: the takeover brings Mantel forward, and
///   a Settings window that was open behind another app comes with it, so the focus does go back to the app. (`ActivationPolicyOwner`
///   watches for the use.) If Mantel was in front when the takeover began, there is no app to give it back to: nothing is handed back,
///   and Mantel steps back unless a window is open.
///
/// It never sets the activation policy: it is one of the reasons `ActivationPolicyOwner` decides from. Mantel goes back to being a menu
/// bar app when the takeover has ended and no window of Mantel's is open, and stays an ordinary app while one is.
final class MenuBarTakeover {
    /// How long `begin` waits for Mantel to be the active app, and how often it looks.
    private static let activationWait: Duration = .seconds(1)
    private static let activationInterval: Duration = .milliseconds(25)
    /// After Mantel is active, the menu bar needs a moment to draw its menu in place of the other app's and to let the icons that were
    /// piled at the « back on the bar. A read of the bar that comes sooner finds it as it was.
    private static let settleTime: Duration = .milliseconds(250)

    private(set) var isActive = false
    private var remembered: NSRunningApplication?
    private var observer: (any NSObjectProtocol)?
    private let activation: ActivationPolicyOwner

    init(activation: ActivationPolicyOwner) {
        self.activation = activation
    }

    /// Takes the menu bar over, and returns once it has had a moment to change: whether Mantel is the active app by then. (macOS
    /// brings an app forward only when it is willing, so it may not be: a reveal that nobody clicked often isn't.) When it isn't, the
    /// takeover is still begun, and the caller undoes it (`MenuBarTakeoverPolicy.afterBegin`). Taken over already, it only says.
    func begin() async -> Bool {
        guard !isActive else { return NSApp.isActive }
        isActive = true
        Log.info("reveal", "taking the menu bar over to make room")
        let own = NSRunningApplication.current.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own {
            remembered = front
        }
        activation.takeoverBegan()
        observeActivations(own: own)
        NSApp.activate()

        // Not for ever: an app that can't be activated leaves the menu bar as it was.
        var waited: Duration = .zero
        while !NSApp.isActive, waited < Self.activationWait {
            try? await Task.sleep(for: Self.activationInterval)
            waited += Self.activationInterval
        }
        guard NSApp.isActive else { return false }
        try? await Task.sleep(for: Self.settleTime)
        return NSApp.isActive
    }

    /// Gives the menu bar back. `reactivate` is whether the app it was taken from gets the focus again: not when the person used a
    /// window of Mantel's (Settings, say, opened during the takeover), where they are.
    func end(reactivate: Bool = true) {
        guard isActive else { return }
        isActive = false
        Log.info("reveal", "gave the menu bar back")
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        let hasAppToHandBackTo = remembered.map { !$0.isTerminated } ?? false
        let focus = activation.takeoverEnded(reactivate: reactivate, hasAppToHandBackTo: hasAppToHandBackTo)
        if focus == .handBack, let remembered {
            NSApp.yieldActivation(to: remembered)
            remembered.activate()
        }
        remembered = nil
    }

    private func observeActivations(own: pid_t) {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let activated = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            guard let activated, activated != own else { return }
            MainActor.assumeIsolated { self?.end(reactivate: false) }
        }
    }
}
