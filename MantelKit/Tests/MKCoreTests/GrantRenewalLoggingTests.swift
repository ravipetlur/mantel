import Testing

@testable import MKCore

@Suite("Grant renewal logging", .timeLimit(.minutes(1)))
struct GrantRenewalLoggingTests {
    @Test func aRenewalIsSaidOncePerGrant() {
        var logging = GrantRenewalLogging()
        let first = logging.shouldLog(.renewed, for: .controlCenterApprovals)
        #expect(first, "the first is said")
        // macOS rewrites the file again and again: the rest are routine.
        for _ in 0..<5 {
            let again = logging.shouldLog(.renewed, for: .controlCenterApprovals)
            #expect(!again)
        }
        // The other grant has its own.
        let other = logging.shouldLog(.renewed, for: .menuBarLayout)
        #expect(other)
        let otherAgain = logging.shouldLog(.renewed, for: .menuBarLayout)
        #expect(!otherAgain)
        let firstAgain = logging.shouldLog(.renewed, for: .controlCenterApprovals)
        #expect(!firstAgain)
    }

    @Test func everyFailureToRenewIsSaid() {
        var logging = GrantRenewalLogging()
        for _ in 0..<3 {
            let failed = logging.shouldLog(.couldNotRenew, for: .controlCenterApprovals)
            #expect(failed)
        }
        // A failure doesn't use up the renewal's one line, and a renewal doesn't silence the failures after it.
        let renewed = logging.shouldLog(.renewed, for: .controlCenterApprovals)
        #expect(renewed)
        let failedAfter = logging.shouldLog(.couldNotRenew, for: .controlCenterApprovals)
        #expect(failedAfter)
        let renewedAgain = logging.shouldLog(.renewed, for: .controlCenterApprovals)
        #expect(!renewedAgain)
    }

    @Test func aGrantMadeAnewOrRemovedStartsOver() {
        var logging = GrantRenewalLogging()
        let first = logging.shouldLog(.renewed, for: .controlCenterApprovals)
        #expect(first)
        logging.startOver(.controlCenterApprovals)
        let another = logging.shouldLog(.renewed, for: .controlCenterApprovals)
        #expect(another, "another grant")
        let again = logging.shouldLog(.renewed, for: .controlCenterApprovals)
        #expect(!again)
        // Starting over a grant that never logged anything changes nothing for the others.
        logging.startOver(.menuBarLayout)
        let unchanged = logging.shouldLog(.renewed, for: .controlCenterApprovals)
        #expect(!unchanged)
    }
}
