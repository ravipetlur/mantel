import Foundation

/// The steps of onboarding, in the order they are shown.
public enum OnboardingStep: String, Sendable, CaseIterable {
    case welcome, accessibility, location, dots, done
}

/// What decides which steps onboarding has to show.
public struct OnboardingInputs: Sendable, Equatable {
    public var accessibilityGranted: Bool
    public var install: InstallLocation.Verdict

    public init(accessibilityGranted: Bool, install: InstallLocation.Verdict) {
        self.accessibilityGranted = accessibilityGranted
        self.install = install
    }
}

/// Which steps onboarding shows. A step whose condition is already met is skipped; the welcome, the dots and the last step
/// always show.
public enum OnboardingFlow {
    public static func steps(for inputs: OnboardingInputs) -> [OnboardingStep] {
        OnboardingStep.allCases.filter { isNeeded($0, for: inputs) }
    }

    /// The step after `step` that is still needed, by the inputs as they are now; nil after the last. A step that was met
    /// in the meantime is skipped, and one that has become needed is not missed.
    public static func next(after step: OnboardingStep, for inputs: OnboardingInputs) -> OnboardingStep? {
        steps(for: inputs).first { later($0, than: step) }
    }

    private static func isNeeded(_ step: OnboardingStep, for inputs: OnboardingInputs) -> Bool {
        switch step {
        case .welcome, .dots, .done: true
        case .accessibility: !inputs.accessibilityGranted
        // Only `/Applications` itself does: that is where the hiding method works from.
        case .location: inputs.install != .applications
        }
    }

    private static func later(_ step: OnboardingStep, than other: OnboardingStep) -> Bool {
        guard let index = OnboardingStep.allCases.firstIndex(of: step),
              let otherIndex = OnboardingStep.allCases.firstIndex(of: other)
        else { return false }
        return index > otherIndex
    }
}

/// The words of each step.
public enum OnboardingCopy {
    public static func title(for step: OnboardingStep) -> String {
        switch step {
        case .welcome: "Welcome to Mantel"
        case .accessibility: "Allow Device control and data access"
        case .location: "Move Mantel to Applications"
        case .dots: "The dots"
        case .done: "You're set"
        }
    }

    /// A few short sentences, short enough for the window that never resizes (`OnboardingCopyTests` holds the limit).
    public static func text(for step: OnboardingStep, inputs: OnboardingInputs) -> String {
        switch step {
        case .welcome:
            return "Mantel keeps your menu bar tidy. First, a few quick checks."
        case .accessibility:
            return "Mantel reads your menu bar and clicks its icons for you. macOS asks once."
        case .location:
            // A translocated copy can't be moved, so it says what to do by hand. It also has to be quit: the copy opened
            // from Applications would otherwise hand off to this one and quit.
            return inputs.install == .translocated
                ? "Drag Mantel into Applications in Finder, then quit this copy and open Mantel from Applications."
                : "macOS only lets Mantel hide icons when it runs from the Applications folder."
        case .dots:
            return "• shows the icons in Hidden. •• shows the ones in Always Hidden, and appears once you put something there. "
                + "Right-click either dot for Mantel's menu."
        case .done:
            return "Mantel is ready in your menu bar. "
                + "If another menu bar organizer is running, quit it: two at once get confused."
        }
    }

    /// The step's primary button. A translocated copy can't be moved by a button, so its button quits it.
    public static func buttonTitle(for step: OnboardingStep, inputs: OnboardingInputs) -> String {
        switch step {
        case .welcome: "Continue"
        case .accessibility: "Open System Settings"
        case .location: inputs.install == .translocated ? "Quit Mantel" : "Move to Applications"
        case .dots: "Continue"
        case .done: "Done"
        }
    }

    /// Every label the primary button can have, whatever the step and the inputs. The button is sized to the widest of them, so
    /// that it is the same width on every step. An input that comes to change a label has to be one of the cases below.
    public static let buttonTitles: [String] = {
        let installs: [InstallLocation.Verdict] = [.applications, .userApplications, .translocated, .elsewhere("")]
        var titles: [String] = []
        for step in OnboardingStep.allCases {
            for granted in [false, true] {
                for install in installs {
                    let inputs = OnboardingInputs(accessibilityGranted: granted, install: install)
                    let title = buttonTitle(for: step, inputs: inputs)
                    if !titles.contains(title) { titles.append(title) }
                }
            }
        }
        return titles
    }()
}
