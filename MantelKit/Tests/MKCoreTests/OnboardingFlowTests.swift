import Testing

@testable import MKCore

@Suite("OnboardingFlow")
struct OnboardingFlowTests {
    private var satisfied: OnboardingInputs {
        OnboardingInputs(accessibilityGranted: true, install: .applications)
    }

    // MARK: Which steps

    @Test func everythingSatisfiedIsWelcomeAndDone() {
        #expect(OnboardingFlow.steps(for: satisfied) == [.welcome, .done])
    }

    @Test func missingAccessibilityAddsItsStep() {
        var inputs = satisfied
        inputs.accessibilityGranted = false
        #expect(OnboardingFlow.steps(for: inputs) == [.welcome, .accessibility, .done])
    }

    @Test(arguments: [InstallLocation.Verdict.userApplications, .translocated, .elsewhere("/Users/x/Downloads")])
    func anywhereButApplicationsAddsTheLocationStep(install: InstallLocation.Verdict) {
        var inputs = satisfied
        inputs.install = install
        #expect(OnboardingFlow.steps(for: inputs) == [.welcome, .location, .done])
    }

    @Test func everythingUnmetIsEveryStepInTheFixedOrder() {
        let inputs = OnboardingInputs(accessibilityGranted: false, install: .translocated)
        #expect(OnboardingFlow.steps(for: inputs) == [.welcome, .accessibility, .location, .done])
        #expect(OnboardingFlow.steps(for: inputs) == OnboardingStep.allCases)
    }

    @Test func theStepsAreInTheOrderOfTheCases() {
        #expect(OnboardingStep.allCases == [.welcome, .accessibility, .location, .done])
    }

    // MARK: Moving on

    @Test func nextIsTheFollowingStepOfTheCurrentInputs() {
        let inputs = OnboardingInputs(accessibilityGranted: false, install: .elsewhere("/tmp"))
        #expect(OnboardingFlow.next(after: .welcome, for: inputs) == .accessibility)
        #expect(OnboardingFlow.next(after: .accessibility, for: inputs) == .location)
        #expect(OnboardingFlow.next(after: .location, for: inputs) == .done)
        #expect(OnboardingFlow.next(after: .done, for: inputs) == nil)
    }

    @Test func aStepThatBecameSatisfiedIsSkipped() {
        // Accessibility was granted while the welcome step was showing.
        let inputs = OnboardingInputs(accessibilityGranted: true, install: .elsewhere("/tmp"))
        #expect(OnboardingFlow.next(after: .welcome, for: inputs) == .location)
    }

    @Test func aStepThatBecameNeededIsNotMissed() {
        // Accessibility was revoked while the welcome step was showing.
        let inputs = OnboardingInputs(accessibilityGranted: false, install: .applications)
        #expect(OnboardingFlow.next(after: .welcome, for: inputs) == .accessibility)
    }

    @Test func nextFromTheStepThatJustGotSatisfiedStillMovesOn() {
        // The accessibility step asks for the next step after it is trusted, when its own step is no longer needed.
        #expect(OnboardingFlow.next(after: .accessibility, for: satisfied) == .done)
        #expect(OnboardingFlow.next(after: .location, for: satisfied) == .done)
    }

    // MARK: Copy

    @Test func titlesAndButtonsAreTheOnesTheStepsShow() {
        let inputs = OnboardingInputs(accessibilityGranted: false, install: .elsewhere("/tmp"))
        let expected: [(OnboardingStep, String, String)] = [
            (.welcome, "Welcome to Mantel", "Continue"),
            (.accessibility, "Allow Accessibility", "Open System Settings"),
            (.location, "Move Mantel to Applications", "Move to Applications"),
            (.done, "You're set", "Done"),
        ]
        for (step, title, button) in expected {
            #expect(OnboardingCopy.title(for: step) == title)
            #expect(OnboardingCopy.buttonTitle(for: step, inputs: inputs) == button)
        }
    }

    @Test func everyStepHasATitleAndAButton() {
        for step in OnboardingStep.allCases {
            #expect(!OnboardingCopy.title(for: step).isEmpty)
            #expect(!OnboardingCopy.buttonTitle(for: step, inputs: satisfied).isEmpty)
        }
    }

    @Test func theButtonTitlesHoldEveryLabelAnyStepGivesIt() {
        // The button is sized to the widest of these, so a label missing from them could make it wider on one step.
        let installs: [InstallLocation.Verdict] = [.applications, .userApplications, .translocated, .elsewhere("/tmp/x")]
        for step in OnboardingStep.allCases {
            for granted in [true, false] {
                for install in installs {
                    let inputs = OnboardingInputs(accessibilityGranted: granted, install: install)
                    #expect(OnboardingCopy.buttonTitles.contains(OnboardingCopy.buttonTitle(for: step, inputs: inputs)))
                }
            }
        }
    }

    @Test func theButtonTitlesAreTheFiveLabelsOnceEach() {
        #expect(OnboardingCopy.buttonTitles.sorted()
            == ["Continue", "Done", "Move to Applications", "Open System Settings", "Quit Mantel"])
    }

    @Test func textsAreTheOnesTheStepsShow() {
        let inputs = OnboardingInputs(accessibilityGranted: false, install: .elsewhere("/tmp"))
        #expect(OnboardingCopy.text(for: .welcome, inputs: inputs)
            == "Mantel keeps your menu bar tidy. First, a few quick checks.")
        #expect(OnboardingCopy.text(for: .accessibility, inputs: inputs)
            == "Mantel reads your menu bar and clicks its icons for you. macOS asks once.")
        #expect(OnboardingCopy.text(for: .location, inputs: inputs)
            == "macOS only lets Mantel hide icons when it runs from the Applications folder.")
        #expect(OnboardingCopy.text(for: .done, inputs: inputs)
            == "Mantel's icon is the dot in your menu bar. If another menu bar organizer is running, quit it: two at once get confused.")
    }

    @Test func aTranslocatedCopyIsToldToDragItAndOnlyHasQuit() {
        // It can't be moved, and it can't be left running: the copy in Applications would hand off to it and quit.
        let inputs = OnboardingInputs(accessibilityGranted: true, install: .translocated)
        #expect(OnboardingCopy.text(for: .location, inputs: inputs)
            == "Drag Mantel into Applications in Finder, then quit this copy and open Mantel from Applications.")
        #expect(OnboardingCopy.buttonTitle(for: .location, inputs: inputs) == "Quit Mantel")
        #expect(OnboardingCopy.title(for: .location) == "Move Mantel to Applications")
    }
}
