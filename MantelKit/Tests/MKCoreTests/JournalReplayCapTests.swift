import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

/// A restorer that restores at once.
private struct InstantRestorer: JournalRestoring {
    func restore(_ entry: JournalEntry) async throws {}
}

/// A restorer that hangs, until the replay is given up on and its task is cancelled.
private struct HangingRestorer: JournalRestoring {
    func restore(_ entry: JournalEntry) async throws {
        try await Task.sleep(for: .seconds(3600))
    }
}

@Suite("Journal replay cap", .timeLimit(.minutes(1)))
struct JournalReplayCapTests {
    /// Held by the suite, and so for the whole test.
    let folder = TemporaryFolder(prefix: "mantel-replay-cap")
    let clock = FakeClock()

    private func makeJournal() -> Journal { Journal(file: folder.url.appending(path: "journal.json"), clock: clock) }

    private func entry(_ key: String) -> JournalEntry {
        .plistKey(filePath: "/tmp/example.plist", key: key, original: .integer(1), strategy: .atomicFile)
    }

    @Test func aReplayThatFinishesInTimeIsReportedAsCompleted() async throws {
        let journal = makeJournal()
        try await journal.record(entry("a"))
        let outcome = await journal.replay(using: InstantRestorer(), cap: .seconds(10), clock: clock)
        #expect(outcome == .completed([]))
        #expect(await journal.records().isEmpty)
    }

    @Test func aFinishedReplayStopsTheTimer() async throws {
        let journal = makeJournal()
        try await journal.record(entry("a"))
        _ = await journal.replay(using: InstantRestorer(), cap: .seconds(10), clock: clock)
        #expect(clock.sleeperCount == 0, "nothing is left waiting for the cap")
    }

    @Test func failuresAreReportedWithTheOutcome() async throws {
        struct Failing: JournalRestoring {
            func restore(_ entry: JournalEntry) async throws { throw CocoaError(.fileWriteNoPermission) }
        }
        let journal = makeJournal()
        try await journal.record(entry("a"))
        guard case .completed(let failures) = await journal.replay(using: Failing(), cap: .seconds(10), clock: clock) else {
            Issue.record("the replay completed")
            return
        }
        #expect(failures.map(\.key) == ["plist:/tmp/example.plist#a"])
    }

    @Test func aReplayThatHangsIsGivenUpOnAtTheCapAndItsEntriesStay() async throws {
        let journal = makeJournal()
        try await journal.record(entry("a"))
        try await journal.record(entry("b"))

        let replay = Task { await journal.replay(using: HangingRestorer(), cap: .seconds(10), clock: clock) }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(9))
        #expect(clock.sleeperCount == 1, "not yet")
        clock.advance(by: .seconds(1))

        #expect(await replay.value == .timedOut)
        // What wasn't restored is still there for the next launch.
        #expect(await journal.records().count == 2)
    }
}
