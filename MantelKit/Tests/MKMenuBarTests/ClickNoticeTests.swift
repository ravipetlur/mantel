import Foundation
import Testing

@testable import MKMenuBar

/// Which clicks the person is told about, and how: a toast, an alert, or nothing.
@Suite("Click notice", .timeLimit(.minutes(1)))
struct ClickNoticeTests {
    private let failures: [IconClickFailure] = [.noRoom, .refused("no"), .hiddenBar, .notRunning, .unreachable]

    @Test func aClickThatWasMadeSaysNothing() {
        let outcome = IconClickOutcome.clicked(.pressedDrawn)
        #expect(ClickNotice.of(outcome, app: "Weather", mantelIsTrusted: { true }) == .nothing)
        #expect(ClickNotice.of(outcome, app: "Weather", mantelIsTrusted: { false }) == .nothing)
    }

    @Test func eachFailureIsAToastWhenMantelIsTrusted() {
        for failure in failures {
            #expect(ClickNotice.of(.failed(failure), app: "Weather", mantelIsTrusted: { true })
                    == .toast(ToastCopy.click(failure, app: "Weather")), "\(failure)")
        }
    }

    @Test func aRefusedPressWithoutMantelsOwnGrantIsAnAlert() {
        #expect(ClickNotice.of(.failed(.refused("no")), app: "Weather", mantelIsTrusted: { false }) == .alert(ClickNotice.needsGrant))
    }

    @Test func everyFailureButNotRunningIsTakenForAMissingGrantWhenMantelIsntTrusted() {
        for failure in failures where failure != .notRunning {
            #expect(ClickNotice.of(.failed(failure), app: "Weather", mantelIsTrusted: { false }) == .alert(ClickNotice.needsGrant), "\(failure)")
        }
        // An app that isn't running is the app's matter, whatever Mantel is granted.
        #expect(ClickNotice.of(.failed(.notRunning), app: "Weather", mantelIsTrusted: { false })
                == .toast(ToastCopy.click(.notRunning, app: "Weather")))
    }

    @Test func aClickThatAnotherTookOverSaysNothingWhetherOrNotMantelIsTrusted() {
        #expect(ClickNotice.of(.overtaken, app: "Weather", mantelIsTrusted: { true }) == .nothing)
        #expect(ClickNotice.of(.overtaken, app: "Weather", mantelIsTrusted: { false }) == .nothing)
    }

    @Test func trustIsOnlyAskedForAFailure() {
        var asked = 0
        for failure in failures {
            _ = ClickNotice.of(.failed(failure), app: "Weather", mantelIsTrusted: { asked += 1; return true })
        }
        #expect(asked == failures.filter { $0 != .notRunning }.count)
        asked = 0
        _ = ClickNotice.of(.clicked(.pressedDrawn), app: "Weather", mantelIsTrusted: { asked += 1; return true })
        _ = ClickNotice.of(.overtaken, app: "Weather", mantelIsTrusted: { asked += 1; return true })
        #expect(asked == 0)
    }

    @Test func anIconThatCantBeShownIsNeverTheGrantAlert() {
        // Showing an icon clicks nothing, so Mantel's grant isn't what is missing, whatever it is granted.
        for failure in failures {
            #expect(ClickNotice.ofShow(failure, app: "Weather") == .toast(ToastCopy.click(failure, app: "Weather")), "\(failure)")
            #expect(ClickNotice.ofShow(failure, app: "Weather", announces: false) == .nothing, "\(failure)")
        }
    }

    @Test func aCommandThatAnswersInItsOwnWordsHearsNothing() {
        for failure in failures {
            #expect(ClickNotice.of(.failed(failure), app: "Weather", mantelIsTrusted: { false }, announces: false) == .nothing, "\(failure)")
        }
    }

    @Test func theAlertSaysExactlyWhatItShould() {
        #expect(ClickNotice.needsGrant.title == "Mantel can't click icons")
        #expect(ClickNotice.needsGrant.text == "Turn on Mantel in System Settings › Privacy & Security › Device control and data access.")
        #expect(ClickNotice.needsGrant.defaultButton == "Open System Settings")
        #expect(ClickNotice.needsGrant.cancelButton == "Cancel")
    }
}
