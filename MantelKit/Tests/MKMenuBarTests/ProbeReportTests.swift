import Foundation
import MKCommands
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

@Suite("Probe report", .timeLimit(.minutes(1)))
struct ProbeReportTests {
    /// Held by the suite, and so for the whole test.
    let folder = TemporaryFolder(prefix: "mantel-probe-report")

    private func report(_ name: ProbeName = .inventory, at seconds: TimeInterval = 1_700_000_000.5,
                        measurements: [String: JSONValue] = ["count": .number(3)]) -> ProbeReport {
        ProbeReport(name: name, startedAt: Date(timeIntervalSince1970: seconds), durationMs: 12.5,
                    environment: ["macOS": "27.0.1"], measurements: measurements, notes: ["a note"], restored: true,
                    errors: [])
    }

    @Test func aReportRoundTripsThroughJSON() throws {
        let original = ProbeReport(
            name: .allowlistActivate, startedAt: Date(timeIntervalSince1970: 1_700_000_000.5), durationMs: 5123.25,
            environment: ["macOS": "27.0.1 (26A434)", "model": "Mac16,1", "mantelVersion": "0.1.0", "displays": "A,B"],
            measurements: ["activateToCompletionMs": .number(112.5), "concealedSlots": .array([.string("x")]),
                           "restored": .bool(true), "problem": .null],
            notes: ["one", "two"], restored: false, errors: ["it broke"])
        let data = try JSONCoding.encoder().encode(original)
        #expect(try JSONCoding.decoder().decode(ProbeReport.self, from: data) == original)
    }

    @Test func theFileNameIsTheProbeAndTheStartTime() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ProbeReport.fileName(for: .inventory, startedAt: start, timeZone: TimeZone(identifier: "UTC")!) == "inventory-20231114-221320.json")
        #expect(ProbeReport.fileName(for: .allowlistActivate, startedAt: start, timeZone: TimeZone(identifier: "UTC")!)
                == "allowlist-activate-20231114-221320.json")
        // Local time, as the Backups folder's names are.
        #expect(ProbeReport.fileName(for: .overflow, startedAt: start, timeZone: TimeZone(identifier: "Asia/Kolkata")!)
                == "overflow-20231115-034320.json")
    }

    @Test func theSnapshotFileSitsBesideTheReport() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ProbeReport.timestamp(startedAt: start, timeZone: TimeZone(identifier: "UTC")!) == "20231114-221320")
    }

    @Test func aStoredReportIsFoundAgainAsTheLatest() throws {
        let store = ProbeReportStore(folder: folder.url)
        let older = report(at: 1_700_000_000)
        let newer = report(at: 1_700_000_100)
        try store.save(older)
        try store.save(newer)
        #expect(store.latest(.inventory) == newer)
        #expect(store.latest(.overflow) == nil)
    }

    @Test func twoReportsInTheSameSecondDontOverwriteEachOther() throws {
        let store = ProbeReportStore(folder: folder.url)
        let first = try store.save(report(measurements: ["n": .number(1)]))
        let second = try store.save(report(measurements: ["n": .number(2)]))
        #expect(first != second)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func aReportFileIsPrivate() throws {
        let store = ProbeReportStore(folder: folder.url)
        let url = try store.save(report())
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func latestIgnoresOtherFilesAndSnapshots() throws {
        let store = ProbeReportStore(folder: folder.url)
        try store.save(report(at: 1_700_000_000))
        try Data("not json".utf8).write(to: folder.url.appending(path: "inventory-20991231-000000.json"))
        try Data("{}".utf8).write(to: folder.url.appending(path: "inventory-20991231-000000-snapshot.json"))
        try Data("{}".utf8).write(to: folder.url.appending(path: "notes.txt"))
        #expect(store.latest(.inventory)?.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func latestOfAProbeNamedLikeAPrefixOfAnotherIsNotConfused() throws {
        // "capture" must not pick up a file of another probe whose name starts with it, nor the reverse.
        let store = ProbeReportStore(folder: folder.url)
        try store.save(report(.capture, at: 1_700_000_000))
        #expect(store.latest(.capture) != nil)
        #expect(store.latest(.clickReplay) == nil)
    }

    @Test func allGivesTheLatestOfEachProbe() throws {
        let store = ProbeReportStore(folder: folder.url)
        try store.save(report(.inventory, at: 1_700_000_000))
        try store.save(report(.inventory, at: 1_700_000_050))
        try store.save(report(.overflow, at: 1_700_000_010))
        let all = store.all()
        #expect(Set(all.keys) == [.inventory, .overflow])
        #expect(all[.inventory]?.startedAt == Date(timeIntervalSince1970: 1_700_000_050))
    }

    @Test func theLatestOfAProbeCanBeFilteredByAMeasurement() throws {
        let store = ProbeReportStore(folder: folder.url)
        try store.save(report(.screenShare, at: 1_700_000_000, measurements: ["phase": .string("before")]))
        try store.save(report(.screenShare, at: 1_700_000_100, measurements: ["phase": .string("during")]))
        let before = store.latest(.screenShare) { $0.measurements["phase"] == .string("before") }
        #expect(before?.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }
}
