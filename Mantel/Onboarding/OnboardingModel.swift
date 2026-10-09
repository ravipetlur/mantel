import Foundation
import MKCore
import Observation

/// Where onboarding is, and what it knows of the Mac. `refresh()` (once a second while the window is open) reads the Mac
/// again.
@Observable
final class OnboardingModel {
    private(set) var step: OnboardingStep = .welcome
    private(set) var inputs: OnboardingInputs
    /// A move to Applications is under way (or has been made): the button for it stays off, so that it can't be pressed
    /// again while the first is waiting for the copy in Applications to start.
    private(set) var isMoving = false
    private let finish: () -> Void

    /// `finish` is called when the person presses Done.
    init(finish: @escaping () -> Void) {
        self.finish = finish
        inputs = Self.currentInputs()
    }

    static func currentInputs() -> OnboardingInputs {
        OnboardingInputs(accessibilityGranted: AccessibilityTrust.isTrusted,
                         install: InstallLocation.verdict(for: Bundle.main.bundleURL))
    }

    /// Reads the Mac again. The accessibility step moves on by itself once Mantel is trusted.
    func refresh() {
        update()
        if step == .accessibility, inputs.accessibilityGranted {
            advance()
        }
    }

    /// To the next step that is still needed, by what the Mac says now.
    func advance() {
        update()
        if let next = OnboardingFlow.next(after: step, for: inputs) {
            step = next
        }
    }

    /// Reads the Mac, and tells the window only if something is different.
    private func update() {
        let fresh = Self.currentInputs()
        if fresh != inputs { inputs = fresh }
    }

    /// Moves Mantel to Applications and starts it there. One at a time, and none after one has worked: the second would find
    /// the copy just moved in Applications and offer to replace it.
    func moveToApplications() async {
        guard !isMoving else { return }
        isMoving = true
        let hasMoved = await AppMover.moveToApplicationsAndRelaunch()
        // After a move this copy is on its way out, and the bundle it was run from is gone.
        if !hasMoved { isMoving = false }
    }

    func done() {
        finish()
    }
}
