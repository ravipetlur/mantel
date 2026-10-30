import Testing

@testable import MKCore

@Suite("Onboarding copy", .timeLimit(.minutes(2)))
struct OnboardingCopyTests {
    private let installs: [InstallLocation.Verdict] = [.applications, .userApplications, .translocated, .elsewhere("/tmp/x")]

    @Test func buttonTitlesIncludeEveryStep() {
        // A step added later is in the button's width without anyone listing its label: the labels come from the steps themselves.
        for step in OnboardingStep.allCases {
            for granted in [true, false] {
                for install in installs {
                    let title = OnboardingCopy.buttonTitle(for: step, inputs: OnboardingInputs(accessibilityGranted: granted, install: install))
                    #expect(OnboardingCopy.buttonTitles.contains(title), "\(step) says “\(title)”, which the button isn't sized for")
                }
            }
        }
        #expect(OnboardingCopy.buttonTitles.contains("Continue"))
    }

    @Test func everyStepsTextIsShortEnoughForTheWindow() {
        // The text sits above the button in a window that never resizes: it has to stay short enough to fit, whatever it says in how
        // many sentences (the dots step says three).
        for step in OnboardingStep.allCases {
            for install in installs {
                let text = OnboardingCopy.text(for: step, inputs: OnboardingInputs(accessibilityGranted: false, install: install))
                #expect(!text.isEmpty)
                #expect(text.count < 260, "\(step)'s text is \(text.count) characters")
            }
        }
    }
}
