import Foundation
import MKUpdate
import Testing

/// When the next background check is due: the first one five minutes after launch, then once a day, and a clock that moved back
/// never pushes a check out for ever.
@Suite("The update schedule", .timeLimit(.minutes(2)))
struct UpdateScheduleTests {
    let minute: TimeInterval = 60
    let day: TimeInterval = 86_400

    /// Fixed instants, so the arithmetic is exact: the app launched an hour before "now".
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var launch: Date { now.addingTimeInterval(-3600) }

    func next(lastCheck: Date?, now: Date? = nil, automatic: Bool = true) -> Date? {
        UpdateSchedule.nextCheck(lastCheck: lastCheck, launch: launch, now: now ?? self.now, automatic: automatic)
    }

    @Test func theDelaysAreFiveMinutesAndADay() {
        #expect(UpdateSchedule.firstCheckDelay == 5 * minute)
        #expect(UpdateSchedule.interval == day)
    }

    @Test func automaticOffNeverSchedulesACheck() {
        #expect(next(lastCheck: nil, automatic: false) == nil)
        #expect(next(lastCheck: now.addingTimeInterval(-3 * day), automatic: false) == nil)
    }

    /// With no last check, or one more than a day old, the check is five minutes after launch (and so due already when the
    /// launch was longer ago); with a recent one, a day after it.
    @Test func theFirstCheckFollowsTheLaunchAndLaterOnesTheLastCheck() {
        #expect(next(lastCheck: nil) == launch.addingTimeInterval(5 * minute))
        #expect(next(lastCheck: now.addingTimeInterval(-day - 1)) == launch.addingTimeInterval(5 * minute))
        #expect(next(lastCheck: now.addingTimeInterval(-3 * 365 * day)) == launch.addingTimeInterval(5 * minute))
        let recent = now.addingTimeInterval(-2 * 3600)
        #expect(next(lastCheck: recent) == recent.addingTimeInterval(day))
        #expect(next(lastCheck: now) == now.addingTimeInterval(day))
        #expect(next(lastCheck: now.addingTimeInterval(-day + 30)) == now.addingTimeInterval(30))
        // Exactly a day old is due now, not pushed forward.
        #expect(next(lastCheck: now.addingTimeInterval(-day)) == now)
    }

    /// The clock moved back: a last check in the future counts as now, so the next check is a day away, not a day after a time
    /// that hasn't come. Corrected once, the answer stops moving.
    @Test func aLastCheckInTheFutureCountsAsNow() {
        for ahead in [1.0, 3600, 400 * day] {
            #expect(next(lastCheck: now.addingTimeInterval(ahead)) == now.addingTimeInterval(day))
        }
        let corrected = UpdateSchedule.correctedLastCheck(stored: now.addingTimeInterval(5 * day), now: now)
        #expect(corrected == now)
        #expect(next(lastCheck: corrected, now: now.addingTimeInterval(3600)) == now.addingTimeInterval(day))
        #expect(UpdateSchedule.correctedLastCheck(stored: now.addingTimeInterval(-5), now: now) == now.addingTimeInterval(-5))
        #expect(UpdateSchedule.correctedLastCheck(stored: nil, now: now) == nil)
    }

    /// Asking again later doesn't push the check out.
    @Test func askingLaterDoesNotMoveTheNextCheck() {
        let last = now.addingTimeInterval(-3600)
        #expect(next(lastCheck: last, now: now.addingTimeInterval(600)) == next(lastCheck: last))
        #expect(next(lastCheck: nil, now: now.addingTimeInterval(120)) == next(lastCheck: nil))
    }

    // MARK: Whether a background check may start

    @Test func aBackgroundCheckNeverChangesWhatIsRunningOrBeingRead() {
        let release = Releases.current
        var running: [InstallFlow.State] = [.checking, .downloading(progress: 0), .downloading(progress: 0.7), .installing, .handedOff(release)]
        running += VerifyStep.allCases.map { .verifying(step: $0) }
        for state in running {
            #expect(!UpdateSchedule.backgroundCheckMayStart(state: state, offerWindowOpen: false), "\(state)")
        }
        let resting: [InstallFlow.State] = [.idle, .upToDate, .available(release), .failed(.network), .failed(.installFailed), .cancelled]
        for state in resting {
            #expect(UpdateSchedule.backgroundCheckMayStart(state: state, offerWindowOpen: false), "\(state)")
            #expect(!UpdateSchedule.backgroundCheckMayStart(state: state, offerWindowOpen: true), "\(state)")
        }
    }
}
