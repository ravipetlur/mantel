import Foundation
import MKCommands
import MKCore
import Testing

@testable import MKMenuBar

@Suite("Diagnostics formatting", .timeLimit(.minutes(1)))
struct DiagnosticsFormattingTests {
    private let home = "/Users/someone"

    private let checks = [
        DiagnosticsCheck(title: "Device control and data access", status: .ok, detail: "Granted"),
        DiagnosticsCheck(title: "Layout file", status: .warning, detail: "Found at /Users/someone/Library/x.plist, not granted"),
    ]

    // MARK: Redaction

    @Test(arguments: [
        ("/Users/someone/Library/Logs/Mantel/mantel.log", "/Users/someone", "~/Library/Logs/Mantel/mantel.log"),
        ("a /Users/someone b /Users/someone/c", "/Users/someone", "a ~ b ~/c"),
        // A longer name that starts like the home folder is left alone.
        ("/Users/someone2/file", "/Users/someone", "/Users/someone2/file"),
        ("/Users/someone.old/file", "/Users/someone", "/Users/someone.old/file"),
        // Text without the home folder is as it was.
        ("nothing to hide", "/Users/someone", "nothing to hide"),
        ("/Applications/Mantel.app", "/Users/someone", "/Applications/Mantel.app"),
        // A home folder that has regex characters is matched literally.
        ("/Users/a.b+c/x", "/Users/a.b+c", "~/x"),
        ("/Users/aXb+c/x", "/Users/a.b+c", "/Users/aXb+c/x"),
        // An empty home folder changes nothing.
        ("/Users/someone/x", "", "/Users/someone/x"),
        ("/Users/someone/x", "/", "/Users/someone/x"),
    ])
    func theHomeFolderBecomesATilde(text: String, home: String, redacted: String) {
        #expect(DiagnosticsText.redact(text, home: home) == redacted)
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

    // MARK: The report

    @Test func theReportHasTheChecks() {
        let text = DiagnosticsText.render(checks: checks, home: home)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "Mantel diagnostics")
        #expect(text.contains("Device control and data access: OK. Granted"))
        #expect(text.contains("Layout file: Needs attention. Found at ~/Library/x.plist, not granted"))
    }

    @Test func theReportNeverHasTheHomeFolderInIt() {
        let text = DiagnosticsText.render(checks: checks, home: home)
        #expect(!text.contains("/Users/someone"))
        #expect(text.contains("~/Library/x.plist"))
    }

    @Test func theJSONFormHasTheChecksWithTheHomeRedacted() {
        let json = DiagnosticsText.json(checks: checks, home: home)
        guard case .object(let object) = json, case .array(let list)? = object["checks"] else {
            Issue.record("an object with checks")
            return
        }
        #expect(list.count == 2)
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

    @Test func reachRowsCopiedWithBundleIDsOnly() {
        let reach = [AppReach(bundleID: "com.example.beta", name: "Sam's Private Tool", status: .fine, readMs: 5),
                     AppReach(bundleID: "com.example.alpha", name: "Home Wi-Fi Helper", status: .slow, readMs: 140)]
        // An item's label can hold the person's own words (a network's name, a battery level): it is not in the copy either.
        let labelled = MenuBarItem(id: ItemID(bundleID: "com.example.alpha", key: .identifier("main")), ownerBundleID: "com.example.alpha",
                                   appName: "Home Wi-Fi Helper", label: "Connected to Sam's Network", frames: [:], overflowedOn: [], isMantel: false)
        let blocks = HidingDiagnostics.blocks(engine: nil, inventory: inventory(reach: reach, items: [labelled]))
        let block = blocks.first { $0.title == "How apps answer Mantel" }
        #expect(block?.lines == ["com.example.alpha: Slow (140 ms)", "com.example.beta: Fine"])

        let text = DiagnosticsText.render(checks: [], blocks: blocks, home: home)
        #expect(text.contains("com.example.alpha: Slow (140 ms)"))
        for leak in ["Sam", "Home Wi-Fi", "Private Tool", "Connected to"] {
            #expect(!text.contains(leak), "\(leak) isn't in the copy")
        }
        let json = DiagnosticsText.json(checks: [], blocks: blocks, home: home)
        let encoded = String(decoding: (try? JSONEncoder().encode(json)) ?? Data(), as: UTF8.self)
        #expect(encoded.contains("com.example.beta: Fine"))
        for leak in ["Sam", "Home Wi-Fi", "Private Tool", "Connected to"] {
            #expect(!encoded.contains(leak))
        }
    }

    @Test func theBlocksAreInTheReportAfterTheChecks() {
        let blocks = HidingDiagnostics.blocks(engine: nil, inventory: nil)
        #expect(blocks.map(\.title) == ["Ways of hiding", "What hiding changes", "How apps answer Mantel"])
        let text = DiagnosticsText.render(checks: checks, blocks: blocks, home: home)
        let lastCheck = text.range(of: "Layout file")!.lowerBound
        let ways = text.range(of: "Ways of hiding")!.lowerBound
        #expect(lastCheck < ways)
        #expect(text.contains(EngineNotes.sideEffects))
        #expect(text.contains(EngineNotes.clockNote))
        #expect(text.contains(EngineNotes.crashNote))
    }

    @Test func theJSONFormHasSectionsOnlyWhenThereAreBlocks() {
        guard case .object(let without) = DiagnosticsText.json(checks: checks, home: home) else {
            Issue.record("an object")
            return
        }
        #expect(without["sections"] == nil)

        let blocks = [DiagnosticsBlock(title: "Ways of hiding", lines: ["Allowlist: available"])]
        guard case .object(let with) = DiagnosticsText.json(checks: checks, blocks: blocks, home: home) else {
            Issue.record("an object")
            return
        }
        #expect(with["sections"] == .array([.object(["title": .string("Ways of hiding"), "lines": .array([.string("Allowlist: available")])])]))
    }
}
