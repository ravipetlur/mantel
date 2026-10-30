import Foundation
import MKUpdate
import Testing

/// After the swap of the running app for the new copy reports an error, what to do with what is on disk, so that the current
/// app is never lost while a good copy exists.
///
/// `NSFileOriginalItemLocationKey` comes with the error only when the old app isn't at its original place, so the key together
/// with something at the app's place means the swap took effect; without the key, something at the app's place is the old app.
@Suite("Recovering from a failed swap", .timeLimit(.minutes(2)))
struct ReplaceRecoveryTests {
    typealias Plan = ReplaceRecovery.Plan

    func plan(inPlace: Bool = false, reported: Bool = false, original: Bool = false, backup: Bool = false,
              staged: Bool = true) -> Plan {
        ReplaceRecovery.plan(appInPlace: inPlace, originalLocationReported: reported, originalLocationExists: original,
                             backupExists: backup, stagedExists: staged)
    }

    @Test func anAppMovedAwayIsPutBackFromWhereItIs() {
        #expect(plan(reported: true, original: true) == .restoreFromOriginalLocation)
        #expect(plan(reported: true, original: true, staged: false) == .restoreFromOriginalLocation)
        #expect(plan(backup: true) == .restoreFromBackup)
        #expect(plan(reported: true, original: false, backup: true) == .restoreFromBackup)
        #expect(plan(backup: true, staged: false) == .restoreFromBackup)
        // A restore that failed leaves the verified staged copy to take the app's place; the app is lost only when that is gone too.
        #expect(ReplaceRecovery.planAfterFailedRestore(stagedExists: true) == .promoteStaged)
        #expect(ReplaceRecovery.planAfterFailedRestore(stagedExists: false) == .appLost)
    }

    @Test func everyCombinationHasTheRightPlan() {
        for inPlace in [false, true] {
            for reported in [false, true] {
                for original in [false, true] {
                    for backup in [false, true] {
                        for staged in [false, true] {
                            let result = plan(inPlace: inPlace, reported: reported, original: original, backup: backup, staged: staged)
                            let context = "inPlace \(inPlace), reported \(reported), original \(original), backup \(backup), staged \(staged)"
                            #expect((result == .discardStaged) == (inPlace && !reported), "\(context)")
                            #expect((result == .keepNewCopy) == (inPlace && reported), "\(context)")
                            let restores = !inPlace && ((reported && original) || backup)
                            #expect((result == .restoreFromOriginalLocation || result == .restoreFromBackup) == restores, "\(context)")
                            #expect((result == .appLost) == (!inPlace && !restores && !staged), "\(context)")
                            #expect((result == .promoteStaged) == (!inPlace && !restores && staged), "\(context)")
                        }
                    }
                }
            }
        }
    }

    // MARK: The running app is never the old copy

    let running = URL(filePath: "/Users/someone/Apps/Mantel.app", directoryHint: .isDirectory)

    /// What the error names as the old app's place is deleted after the swap, so it must never be the running app's own place
    /// (where the new copy now is), however that place is spelled: it is taken as no key.
    @Test func aReportedLocationThatIsTheRunningAppIsNotReported() {
        let spellings = ["/Users/someone/Apps/Mantel.app/", "/Users/someone/Apps/./Mantel.app",
                         "/Users/someone/Apps/Other/../Mantel.app", "/Users/someone/Apps//Mantel.app", "/Users/someone/Apps/Mantel.app"]
        for spelling in spellings {
            for hint in [URL.DirectoryHint.isDirectory, .notDirectory, .inferFromPath] {
                let reported = URL(filePath: spelling, directoryHint: hint)
                #expect(ReplaceRecovery.reportedOriginalLocation(reported, running: running) == nil, "\(spelling) \(hint)")
                #expect(ReplaceRecovery.isRunningApp(reported, running: running), "\(spelling) \(hint)")
            }
        }
        let reported = ReplaceRecovery.reportedOriginalLocation(running, running: running)
        #expect(plan(inPlace: true, reported: reported != nil, original: true) == .discardStaged)
        #expect(ReplaceRecovery.reportedOriginalLocation(nil, running: running) == nil)
    }

    @Test func aReportedLocationElsewhereIsKept() {
        for place in ["/Users/someone/Apps/Mantel 1.1.app", "/Users/someone/Other/Mantel.app", "/Users/someone/Apps/Mantel.app/Contents"] {
            let old = URL(filePath: place, directoryHint: .isDirectory)
            #expect(ReplaceRecovery.reportedOriginalLocation(old, running: running) == old)
            #expect(!ReplaceRecovery.isRunningApp(old, running: running))
        }
    }
}
