import Foundation
import MKCommands
import MKCore
import Testing

@testable import MKMenuBar

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let members) = self { members } else { nil }
    }
}

@Suite("Diagnostics formatting", .timeLimit(.minutes(1)))
struct DiagnosticsFormattingTests {
    private let home = "/Users/someone"
    private let utc = TimeZone(identifier: "UTC")!

    private func report(_ name: ProbeName, at seconds: TimeInterval = 1_700_000_000, restored: Bool = true,
                        errors: [String] = [], measurements: [String: JSONValue] = [:]) -> ProbeReport {
        ProbeReport(name: name, startedAt: Date(timeIntervalSince1970: seconds), durationMs: 10, environment: [:],
                    measurements: measurements, notes: [], restored: restored, errors: errors)
    }

    private let checks = [
        DiagnosticsCheck(title: "Device control and data access", status: .ok, detail: "Granted"),
        DiagnosticsCheck(title: "Layout file", status: .warning, detail: "Found at /Users/someone/Library/x.plist, not granted"),
    ]

    // MARK: The journal

    @Test func theJournalLineSaysWhatQuitPutsBackAndWhatIsKept() {
        #expect(JournalSummary.detail(untilQuit: 2, kept: 5) == "2 to put back on quit, 5 kept.")
        #expect(JournalSummary.detail(untilQuit: 0, kept: 0) == "0 to put back on quit, 0 kept.")
        #expect(JournalSummary.detail(untilQuit: 1, kept: 0) == "1 to put back on quit, 0 kept.")
    }

    @Test func onlyTemporaryChangesNeedAttention() {
        // What Mantel keeps is as it should be, and "Replay now" (which the pane disables for an OK line) has nothing to do for it.
        #expect(JournalSummary.check(untilQuit: 0, kept: 3) == DiagnosticsCheck(title: "Journal", status: .ok,
                                                                               detail: "0 to put back on quit, 3 kept."))
        #expect(JournalSummary.check(untilQuit: 0, kept: 0).status == .ok)
        #expect(JournalSummary.check(untilQuit: 1, kept: 3).status == .warning)
        #expect(JournalSummary.check(untilQuit: 4, kept: 0).detail == "4 to put back on quit, 0 kept.")
    }

    // MARK: Redaction

    @Test func theHomeFolderBecomesATilde() {
        #expect(DiagnosticsText.redact("/Users/someone/Library/Logs/Mantel/mantel.log", home: home) == "~/Library/Logs/Mantel/mantel.log")
        #expect(DiagnosticsText.redact("a /Users/someone b /Users/someone/c", home: home) == "a ~ b ~/c")
    }

    @Test func aLongerNameThatStartsLikeTheHomeFolderIsLeftAlone() {
        #expect(DiagnosticsText.redact("/Users/someone2/file", home: home) == "/Users/someone2/file")
        #expect(DiagnosticsText.redact("/Users/someone.old/file", home: home) == "/Users/someone.old/file")
    }

    @Test func textWithoutTheHomeFolderIsAsItWas() {
        #expect(DiagnosticsText.redact("nothing to hide", home: home) == "nothing to hide")
        #expect(DiagnosticsText.redact("/Applications/Mantel.app", home: home) == "/Applications/Mantel.app")
    }

    @Test func aHomeFolderThatHasRegexCharactersIsMatchedLiterally() {
        #expect(DiagnosticsText.redact("/Users/a.b+c/x", home: "/Users/a.b+c") == "~/x")
        #expect(DiagnosticsText.redact("/Users/aXb+c/x", home: "/Users/a.b+c") == "/Users/aXb+c/x")
    }

    @Test func anEmptyHomeFolderChangesNothing() {
        #expect(DiagnosticsText.redact("/Users/someone/x", home: "") == "/Users/someone/x")
        #expect(DiagnosticsText.redact("/Users/someone/x", home: "/") == "/Users/someone/x")
    }

    @Test func redactingAJSONValueReachesEveryString() {
        let value = JSONValue.object([
            "path": .string("/Users/someone/x"), "list": .array([.string("/Users/someone"), .number(3)]),
            "nested": .object(["deep": .string("see /Users/someone/y")]),
        ])
        #expect(DiagnosticsText.redact(value, home: home) == .object([
            "path": .string("~/x"), "list": .array([.string("~"), .number(3)]), "nested": .object(["deep": .string("see ~/y")]),
        ]))
    }

    // MARK: Names

    @Test func namesAreRedactedToCounts() {
        let value = JSONValue.object([
            "titles": .array([.string("Home Wi-Fi"), .string("Battery 80%")]),
            "descriptions": .array([.string("Sam's AirPods")]),
            "newDescriptions": .array([]),
            "names": .array([.string("a"), .string("b"), .string("c")]),
            "labels": .array([.string("x"), .string("y")]),
            "chevronPresent": .bool(true),
            "count": .number(3),
        ])
        #expect(DiagnosticsText.redactNames(value) == .object([
            "titles": .string("‹2 names›"), "descriptions": .string("‹1 name›"), "newDescriptions": .string("‹0 names›"),
            "names": .string("‹3 names›"), "labels": .string("‹2 names›"),
            "chevronPresent": .bool(true), "count": .number(3),
        ]))
    }

    @Test func namesAreRedactedWhereverTheyAre() {
        let value = JSONValue.object([
            "measurements": .object(["descriptions": .array([.string("one"), .string("two")])]),
            "displays": .array([.object(["labels": .array([.string("left")]), "scale": .number(2)])]),
        ])
        #expect(DiagnosticsText.redactNames(value) == .object([
            "measurements": .object(["descriptions": .string("‹2 names›")]),
            "displays": .array([.object(["labels": .string("‹1 name›"), "scale": .number(2)])]),
        ]))
        // What isn't a list of names, under a key that holds them, says nothing of the person and stays.
        #expect(DiagnosticsText.redactNames(.object(["names": .null, "titles": .bool(false)]))
                == .object(["names": .null, "titles": .bool(false)]))
        #expect(DiagnosticsText.redactNames(.object(["names": .string("Home Wi-Fi")])) == .object(["names": .string("‹1 name›")]))
    }

    @Test func bundleIDsStay() {
        let value = JSONValue.object([
            "identifiers": .array([.string("com.apple.menuextra.wifi"), .string("com.example.app.item")]),
            "newIdentifiers": .array([.string("com.apple.controlcenter.screen-recording")]),
            "bundleID": .string("com.example.app"),
            "overflowedItems": .array([.object(["bundleID": .string("com.apple.menuextra.battery"), "index": .number(0)])]),
            "descriptions": .array([.string("Wi-Fi: Home Wi-Fi")]),
        ])
        let redacted = DiagnosticsText.redactNames(value)
        guard case .object(let members) = redacted else {
            Issue.record("an object")
            return
        }
        #expect(members["identifiers"] == value.objectValue?["identifiers"])
        #expect(members["newIdentifiers"] == value.objectValue?["newIdentifiers"])
        #expect(members["bundleID"] == .string("com.example.app"))
        #expect(members["overflowedItems"] == value.objectValue?["overflowedItems"])
        #expect(members["descriptions"] == .string("‹1 name›"))
    }

    @Test func theReportAndTheJSONFormLeaveTheNamesOut() {
        let shared = report(.screenShare, measurements: [
            "phase": .string("during"),
            "identifiers": .array([.string("com.apple.controlcenter.screen-recording")]),
            "descriptions": .array([.string("Sam's AirPods, 80%")]),
            "newDescriptions": .array([.string("Home Wi-Fi"), .string("Recording")]),
        ])
        let text = DiagnosticsText.render(checks: [], probes: [.screenShare: shared], home: home, timeZone: utc)
        #expect(!text.contains("AirPods"))
        #expect(!text.contains("Home Wi-Fi"))
        #expect(text.contains("‹1 name›"))
        #expect(text.contains("‹2 names›"))
        #expect(text.contains("com.apple.controlcenter.screen-recording"))

        let json = DiagnosticsText.json(checks: [], probes: [.screenShare: shared], home: home)
        let encoded = String(decoding: (try? JSONEncoder().encode(json)) ?? Data(), as: UTF8.self)
        #expect(!encoded.contains("AirPods"))
        #expect(!encoded.contains("Home Wi-Fi"))
        #expect(encoded.contains("‹2 names›"))
        #expect(encoded.contains("com.apple.controlcenter.screen-recording"))
        // The report on disk is as it was: only what is copied and answered is changed.
        #expect(shared.strings("descriptions") == ["Sam's AirPods, 80%"])
    }

    // MARK: Summary

    @Test func theSummaryNamesTheProbeTheTimeAndHowItEnded() {
        let line = ProbeSummary.line(for: report(.inventory), timeZone: utc)
        #expect(line == "inventory · 2023-11-14 22:13:20 · restored · no errors")
    }

    @Test func theSummaryCountsErrorsAndSaysWhenNothingIsRestored() {
        let line = ProbeSummary.line(for: report(.approvalsToggle, restored: false, errors: ["a", "b"]), timeZone: utc)
        #expect(line == "approvals-toggle · 2023-11-14 22:13:20 · not restored · 2 errors")
        #expect(ProbeSummary.line(for: report(.capture, errors: ["one"]), timeZone: utc).hasSuffix("1 error"))
    }

    // MARK: The report

    @Test func theReportHasTheChecksThenTheProbes() {
        let text = DiagnosticsText.render(checks: checks, probes: [.overflow: report(.overflow, measurements: ["chevronPresent": .bool(true)])],
                                          home: home, timeZone: utc)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "Mantel diagnostics")
        #expect(text.contains("Device control and data access: OK. Granted"))
        #expect(text.contains("Layout file: Needs attention. Found at ~/Library/x.plist, not granted"))
        #expect(text.contains("overflow · 2023-11-14 22:13:20 · restored · no errors"))
        #expect(text.contains("\"chevronPresent\" : true"))
        let checksAt = text.range(of: "Device control and data access")
        let probesAt = text.range(of: "Last probe reports")
        #expect(checksAt != nil && probesAt != nil)
        if let checksAt, let probesAt { #expect(checksAt.lowerBound < probesAt.lowerBound) }
    }

    @Test func theReportNeverHasTheHomeFolderInIt() {
        let withPath = report(.layoutRead, measurements: ["path": .string("/Users/someone/Library/Group Containers/x")])
        let text = DiagnosticsText.render(checks: checks, probes: [.layoutRead: withPath], home: home, timeZone: utc)
        #expect(!text.contains("/Users/someone"))
        #expect(text.contains("~/Library/Group Containers/x"))
    }

    @Test func onlyProbesThatHaveARunAreInTheReportAndInTheOrderOfTheCommandLine() {
        let text = DiagnosticsText.render(checks: [], probes: [.capture: report(.capture), .inventory: report(.inventory)],
                                          home: home, timeZone: utc)
        #expect(text.contains("inventory ·"))
        #expect(text.contains("capture ·"))
        #expect(!text.contains("overflow ·"))
        let inventory = text.range(of: "inventory ·")!.lowerBound
        let capture = text.range(of: "capture ·")!.lowerBound
        #expect(inventory < capture, "ProbeName order: inventory comes before capture")
    }

    @Test func withNoProbeRunTheReportSaysSo() {
        let text = DiagnosticsText.render(checks: checks, probes: [:], home: home, timeZone: utc)
        #expect(text.contains("No probe has been run."))
    }

    @Test func statusesHaveWords() {
        #expect(DiagnosticsCheck.Status.ok.word == "OK")
        #expect(DiagnosticsCheck.Status.warning.word == "Needs attention")
        #expect(DiagnosticsCheck.Status.problem.word == "Problem")
        #expect(DiagnosticsCheck.Status.unknown.word == "Unknown")
    }

    @Test func aCheckIsCodable() throws {
        let check = DiagnosticsCheck(title: "Journal", status: .warning, detail: "2 changes waiting")
        #expect(try JSONDecoder().decode(DiagnosticsCheck.self, from: JSONEncoder().encode(check)) == check)
    }

    @Test func theJSONFormHasTheChecksAndTheProbesWithTheHomeRedacted() {
        let withPath = report(.layoutRead, measurements: ["path": .string("/Users/someone/x")])
        let json = DiagnosticsText.json(checks: checks, probes: [.layoutRead: withPath], home: home)
        guard case .object(let object) = json, case .array(let list)? = object["checks"], case .object(let probes)? = object["probes"] else {
            Issue.record("an object with checks and probes")
            return
        }
        #expect(list.count == 2)
        #expect(Set(probes.keys) == ["layout-read"])
        let text = String(decoding: (try? JSONEncoder().encode(json)) ?? Data(), as: UTF8.self)
        #expect(!text.contains("/Users/someone"))
        #expect(object["checks"] == .array([
            .object(["title": .string("Device control and data access"), "status": .string("ok"), "detail": .string("Granted")]),
            .object(["title": .string("Layout file"), "status": .string("warning"), "detail": .string("Found at ~/Library/x.plist, not granted")]),
        ]))
    }

    // MARK: Reach and what hiding changes

    private func inventory(reach: [AppReach] = [], items: [MenuBarItem] = [], problems: [InventoryProblem] = []) -> Inventory {
        Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: [], items: items, chevrons: [:], reach: reach, problems: problems)
    }

    @Test func reachRowsSortedByNameWithTheirWords() {
        let reach = [
            AppReach(bundleID: "com.example.zulu", name: "Zulu", status: .skipped, readMs: 0),
            AppReach(bundleID: "com.example.bravo", name: "bravo", status: .slow, readMs: 312.4),
            AppReach(bundleID: "com.example.alpha", name: "Alpha", status: .fine, readMs: 12),
            AppReach(bundleID: "com.example.mike", name: "Mike", status: .timedOut, readMs: 250),
        ]
        let rows = HidingDiagnostics.reachRows(inventory(reach: reach))
        #expect(rows.map(\.name) == ["Alpha", "bravo", "Mike", "Zulu"])
        #expect(rows.map(\.text) == ["Fine", "Slow (312 ms)", "Timed out; asked again in 30 seconds", "Skipped"])
    }

    @Test func anAppThatRefusesAccessibilityHasItsOwnRow() {
        let reach = [AppReach(bundleID: "com.example.refuser", name: "Refuser", status: .refused, readMs: 3),
                     AppReach(bundleID: "com.example.refuser", name: "Refuser", status: .skipped, readMs: 0),
                     AppReach(bundleID: "com.example.other", name: "Other", status: .fine, readMs: 5)]
        let rows = HidingDiagnostics.reachRows(inventory(reach: reach))
        #expect(rows.map(\.text) == ["Fine", "Refuses to answer"], "the one that went worse of the two answers")
        #expect(rows.last?.status == .refused)
        let copied = HidingDiagnostics.blocks(engine: nil, inventory: inventory(reach: reach)).first { $0.title == "How apps answer Mantel" }
        #expect(copied?.lines == ["com.example.other: Fine", "com.example.refuser: Refuses to answer"])
        #expect(inventory(reach: reach).problems.isEmpty, "and Mantel's own grant is not in question")
    }

    @Test func anAppWithTwoProcessesHasOneRowAndItIsTheWorst() {
        let reach = [AppReach(bundleID: "com.example.two", name: "Two", status: .fine, readMs: 5),
                     AppReach(bundleID: "com.example.two", name: "Two", status: .timedOut, readMs: 250),
                     AppReach(bundleID: "com.example.two", name: "Two", status: .slow, readMs: 140),
                     AppReach(bundleID: "com.example.one", name: "One", status: .fine, readMs: 5)]
        let rows = HidingDiagnostics.reachRows(inventory(reach: reach))
        #expect(rows.map(\.bundleID) == ["com.example.one", "com.example.two"])
        #expect(rows.last?.status == .timedOut)
        #expect(Set(rows.map(\.id)).count == rows.count, "the rows have ids of their own")
    }

    @Test func reachRowsUseTheNamesThePaneKnowsThenTheReadsThenTheBundleID() {
        let reach = [AppReach(bundleID: "com.example.a", name: "Read Name", status: .fine, readMs: 1),
                     AppReach(bundleID: "com.example.b", name: nil, status: .fine, readMs: 1)]
        let rows = HidingDiagnostics.reachRows(inventory(reach: reach), names: ["com.example.a": "Pane Name"])
        #expect(rows.map(\.name) == ["com.example.b", "Pane Name"])
        #expect(HidingDiagnostics.reachRows(nil).isEmpty)
    }

    @Test func reachRowsCopiedWithBundleIDsOnly() {
        let reach = [AppReach(bundleID: "com.example.beta", name: "Sam's Private Tool", status: .fine, readMs: 5),
                     AppReach(bundleID: "com.example.alpha", name: "Home Wi-Fi Helper", status: .slow, readMs: 140)]
        // An item's label can hold the person's own words (a network's name, a battery level): it is not in the copy either.
        let labelled = MenuBarItem(id: ItemID(bundleID: "com.example.alpha", key: .identifier("main")), ownerBundleID: "com.example.alpha",
                                   appName: "Home Wi-Fi Helper", label: "Connected to Sam's Network", frames: [:], overflowedOn: [], isMantel: false)
        let blocks = HidingDiagnostics.blocks(engine: nil, inventory: inventory(reach: reach, items: [labelled]))
        let block = blocks.first { $0.title == "How apps answer Mantel" }
        #expect(block?.lines == ["com.example.alpha: Slow (140 ms)", "com.example.beta: Fine"])

        let text = DiagnosticsText.render(checks: [], blocks: blocks, probes: [:], home: home, timeZone: utc)
        #expect(text.contains("com.example.alpha: Slow (140 ms)"))
        for leak in ["Sam", "Home Wi-Fi", "Private Tool", "Connected to"] {
            #expect(!text.contains(leak), "\(leak) isn't in the copy")
        }
        let json = DiagnosticsText.json(checks: [], blocks: blocks, probes: [:], home: home)
        let encoded = String(decoding: (try? JSONEncoder().encode(json)) ?? Data(), as: UTF8.self)
        #expect(encoded.contains("com.example.beta: Fine"))
        for leak in ["Sam", "Home Wi-Fi", "Private Tool", "Connected to"] {
            #expect(!encoded.contains(leak))
        }
    }

    @Test func noReachSaysSo() {
        let block = HidingDiagnostics.blocks(engine: nil, inventory: inventory()).first { $0.title == "How apps answer Mantel" }
        #expect(block?.lines == ["No app has been asked yet."])
    }

    @Test func theBlocksAreInTheReportBetweenTheChecksAndTheProbes() {
        let blocks = HidingDiagnostics.blocks(engine: nil, inventory: nil)
        #expect(blocks.map(\.title) == ["Ways of hiding", "What hiding changes", "How apps answer Mantel"])
        let text = DiagnosticsText.render(checks: checks, blocks: blocks, probes: [:], home: home, timeZone: utc)
        let lastCheck = text.range(of: "Layout file")!.lowerBound
        let ways = text.range(of: "Ways of hiding")!.lowerBound
        let probes = text.range(of: "Last probe reports")!.lowerBound
        #expect(lastCheck < ways && ways < probes)
        #expect(text.contains(EngineNotes.sideEffects))
        #expect(text.contains(EngineNotes.clockNote))
        #expect(text.contains(EngineNotes.crashNote))
    }

    @Test func theJSONFormHasSectionsOnlyWhenThereAreBlocks() {
        guard case .object(let without) = DiagnosticsText.json(checks: checks, probes: [:], home: home) else {
            Issue.record("an object")
            return
        }
        #expect(without["sections"] == nil)

        let blocks = [DiagnosticsBlock(title: "Ways of hiding", lines: ["Allowlist: available"])]
        guard case .object(let with) = DiagnosticsText.json(checks: checks, blocks: blocks, probes: [:], home: home) else {
            Issue.record("an object")
            return
        }
        #expect(with["sections"] == .array([.object(["title": .string("Ways of hiding"), "lines": .array([.string("Allowlist: available")])])]))
    }
}
