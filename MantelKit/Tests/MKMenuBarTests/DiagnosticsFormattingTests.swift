import Foundation
import MKCommands
import MKCore
import Testing

@testable import MKMenuBar

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
        DiagnosticsCheck(title: "Accessibility", status: .ok, detail: "Granted"),
        DiagnosticsCheck(title: "Layout file", status: .warning, detail: "Found at /Users/someone/Library/x.plist, not granted"),
    ]

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
        #expect(text.contains("Accessibility: OK. Granted"))
        #expect(text.contains("Layout file: Needs attention. Found at ~/Library/x.plist, not granted"))
        #expect(text.contains("overflow · 2023-11-14 22:13:20 · restored · no errors"))
        #expect(text.contains("\"chevronPresent\" : true"))
        let checksAt = text.range(of: "Accessibility")
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
            .object(["title": .string("Accessibility"), "status": .string("ok"), "detail": .string("Granted")]),
            .object(["title": .string("Layout file"), "status": .string("warning"), "detail": .string("Found at ~/Library/x.plist, not granted")]),
        ]))
    }
}
