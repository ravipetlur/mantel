import Foundation
import Testing

@testable import MKMenuBar

/// Which clicks the person is told about, and how: a toast, an alert, or nothing.
@Suite("Click notice", .timeLimit(.minutes(1)))
struct ClickNoticeTests {
    private let failures: [IconClickFailure] = [.noRoom, .refused("no"), .hiddenBar, .notRunning, .unreachable]

    @Test(arguments: [IconClickOutcome.clicked(.pressedDrawn), .overtaken], [true, false])
    func aClickThatWasMadeOrTakenOverSaysNothingWhetherOrNotMantelIsTrusted(outcome: IconClickOutcome, trusted: Bool) {
        #expect(ClickNotice.of(outcome, app: "Weather", mantelIsTrusted: { trusted }) == .nothing)
    }

    @Test func eachFailureIsAToastWhenMantelIsTrusted() {
        for failure in failures {
            #expect(ClickNotice.of(.failed(failure), app: "Weather", mantelIsTrusted: { true })
                    == .toast(ToastCopy.click(failure, app: "Weather")), "\(failure)")
        }
    }

    @Test func everyFailureButNotRunningIsTakenForAMissingGrantWhenMantelIsntTrusted() {
        for failure in failures where failure != .notRunning {
            #expect(ClickNotice.of(.failed(failure), app: "Weather", mantelIsTrusted: { false }) == .alert(ClickNotice.needsGrant), "\(failure)")
        }
        // An app that isn't running is the app's matter, whatever Mantel is granted.
        #expect(ClickNotice.of(.failed(.notRunning), app: "Weather", mantelIsTrusted: { false })
                == .toast(ToastCopy.click(.notRunning, app: "Weather")))
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
}
