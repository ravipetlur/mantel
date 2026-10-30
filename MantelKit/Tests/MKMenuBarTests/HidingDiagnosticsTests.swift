import CoreGraphics
import Foundation
import MKCore
import Testing

@testable import MKMenuBar

@Suite("Hiding diagnostics", .timeLimit(.minutes(1)))
struct HidingDiagnosticsTests {
    private func status(kind: HidingEngineKind = .allowlist, reason: String = "Chosen automatically: macOS's allowlist works.",
                        degraded: Bool = false, availability: [HidingEngineKind: String] = [:],
                        unavailable: [HidingEngineKind: String] = [:], lastError: String? = nil) -> EngineStatus {
        EngineStatus(kind: kind, reason: reason, degraded: degraded, availability: availability, lastError: lastError,
                     unavailableReasons: unavailable)
    }

    private func inventory(items: Int = 0, displays: Int = 0, problems: [InventoryProblem] = []) -> Inventory {
        let bars = (0..<displays).map { MenuBarGeometry(displayUUID: "display-\($0)", rect: CGRect(x: 0, y: 0, width: 1500, height: 31), notch: nil) }
        let list = (0..<items).map { index in
            MenuBarItem(id: ItemID(bundleID: "com.example.app", key: .index(index)), ownerBundleID: "com.example.app", appName: nil, label: nil,
                        frames: [:], overflowedOn: [], isMantel: false)
        }
        return Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: bars, items: list, chevrons: [:], reach: [], problems: problems)
    }

    // MARK: Hiding method

    @Test func hidingMethodIsFineWithTheTitleAndTheReason() {
        let check = HidingDiagnostics.hidingMethodCheck(status())
        #expect(check.title == "Hiding method")
        #expect(check.status == .ok)
        #expect(check.detail == "Allowlist. Chosen automatically: macOS's allowlist works.")
    }

    @Test func theSpacerIsAWarningThatSaysWhatItDoesNotDo() {
        let check = HidingDiagnostics.hidingMethodCheck(status(kind: .spacer, reason: "Chosen in Settings › Advanced.", degraded: true))
        #expect(check.status == .warning)
        #expect(check.detail == "Wide spacer (degraded): only icons left of the divider are hidden. Chosen in Settings › Advanced.")
    }

    @Test func aPlanThatCouldNotBeAppliedIsAProblemAndEverythingIsShown() {
        let check = HidingDiagnostics.hidingMethodCheck(status(lastError: "Allowlist couldn't hide icons: macOS said no."))
        #expect(check.status == .problem)
        #expect(check.detail == "Allowlist couldn't hide icons: macOS said no. Mantel is showing everything.")
        // An error with no full stop of its own gets one, so that the sentence after it reads as a sentence.
        #expect(HidingDiagnostics.hidingMethodCheck(status(lastError: "It broke")).detail == "It broke. Mantel is showing everything.")
    }

    @Test func anErrorBeatsTheSpacerWarning() {
        let check = HidingDiagnostics.hidingMethodCheck(status(kind: .spacer, degraded: true, lastError: "Wide spacer couldn't hide icons: x."))
        #expect(check.status == .problem)
    }

    @Test func beforeTheFirstChoiceThereIsNothingToSayYet() {
        let check = HidingDiagnostics.hidingMethodCheck(nil)
        #expect(check.status == .unknown)
        #expect(check.detail == "Not read yet.")
    }

    // MARK: Menu bar

    @Test func theMenuBarRowSaysHowMuchWasRead() {
        let checks = HidingDiagnostics.menuBarChecks(inventory(items: 14, displays: 2))
        #expect(checks == [DiagnosticsCheck(title: "Menu bar", status: .ok, detail: "Read 14 icons on 2 displays.")])
        #expect(HidingDiagnostics.menuBarChecks(inventory(items: 1, displays: 1)).first?.detail == "Read 1 icon on 1 display.")
        #expect(HidingDiagnostics.menuBarChecks(inventory(items: 0, displays: 1)).first?.detail == "Read 0 icons on 1 display.")
    }

    @Test func eachProblemIsAWarningWithItsOwnMessage() {
        let checks = HidingDiagnostics.menuBarChecks(inventory(items: 3, displays: 1, problems: [.agentNotRunning, .ambiguousSpace]))
        #expect(checks.count == 2)
        #expect(checks.allSatisfy { $0.title == "Menu bar" && $0.status == .warning })
        // As it is: this is what the copied report and the command line's answer carry, and neither has a button below.
        #expect(checks.map(\.detail) == [InventoryProblem.agentNotRunning.message, InventoryProblem.ambiguousSpace.message])
        #expect(InventoryProblem.agentNotRunning.message == "MenuBarAgent isn't running.")
    }

    @Test func thePaneSaysToTryRefreshForAProblemRefreshPutsRight() {
        let problems: [InventoryProblem] = [.agentNotRunning, .agentHasNoWindows]
        let checks = HidingDiagnostics.menuBarChecks(inventory(items: 0, displays: 0, problems: problems), suggestingRefresh: true)
        #expect(checks.map(\.detail) == ["MenuBarAgent isn't running. Try Refresh menu bar below.",
                                         "MenuBarAgent has no windows. Try Refresh menu bar below."])
        #expect(checks.allSatisfy { $0.status == .warning })
    }

    @Test func noSuggestionForAProblemRefreshCannotFixOrAlreadyAdvises() {
        // Accessibility not being granted is the Permissions row's; the other one's message already says to choose Refresh Menu Bar.
        let problems: [InventoryProblem] = [.accessibilityNotGranted, .ambiguousSpace]
        let checks = HidingDiagnostics.menuBarChecks(inventory(items: 0, displays: 0, problems: problems), suggestingRefresh: true)
        #expect(checks.map(\.detail) == [InventoryProblem.accessibilityNotGranted.message, InventoryProblem.ambiguousSpace.message])
        #expect(checks.allSatisfy { !$0.detail.contains("below") })
        #expect(HidingDiagnostics.suggestsRefresh(.agentNotRunning))
        #expect(HidingDiagnostics.suggestsRefresh(.agentHasNoWindows))
        #expect(!HidingDiagnostics.suggestsRefresh(.accessibilityNotGranted))
        #expect(!HidingDiagnostics.suggestsRefresh(.ambiguousSpace))
        // Every kind of problem is decided one way or the other: the switch has no `default`, so a new kind doesn't build until it has been
        // thought about here, and each answer is compared with the one the function gives.
        func refreshHelps(_ problem: InventoryProblem) -> Bool {
            switch problem {
            case .agentNotRunning, .agentHasNoWindows: true
            case .accessibilityNotGranted, .ambiguousSpace: false
            }
        }
        for problem in [InventoryProblem.accessibilityNotGranted, .agentNotRunning, .agentHasNoWindows, .ambiguousSpace] {
            #expect(HidingDiagnostics.suggestsRefresh(problem) == refreshHelps(problem), "\(problem)")
        }
    }

    @Test func theCopiedReportAndTheJSONAnswerNeverSayBelow() throws {
        // The rows they are made of are the default ones: no button is below them.
        let everyProblem: [InventoryProblem] = [.accessibilityNotGranted, .agentNotRunning, .agentHasNoWindows, .ambiguousSpace]
        let checks = HidingDiagnostics.menuBarChecks(inventory(items: 1, displays: 1, problems: everyProblem))
        let text = DiagnosticsText.render(checks: checks, probes: [:], home: "/Users/someone", timeZone: TimeZone(identifier: "UTC")!)
        #expect(!text.contains("below"))
        #expect(!text.contains("Try Refresh menu bar"))
        let json = DiagnosticsText.json(checks: checks, probes: [:], home: "/Users/someone")
        let encoded = String(decoding: try JSONEncoder().encode(json), as: UTF8.self)
        #expect(!encoded.contains("below"))
        for problem in everyProblem {
            #expect(text.contains(problem.message))
        }
    }

    @Test func theAppsCopiedReportNeverSaysBelow() throws {
        // What the app's "Copy diagnostics" puts together: the same rows and blocks, through `DiagnosticsText.render`, which it calls
        // (the rows of the layout, the pictures and the spacing are among them).
        let everyProblem: [InventoryProblem] = [.accessibilityNotGranted, .agentNotRunning, .agentHasNoWindows, .ambiguousSpace]
        let state = inventory(items: 1, displays: 1, problems: everyProblem)
        let layout = LayoutDiagnostics.rows(
            layout: nil, images: (count: 0, last: nil, screenRecording: false),
            spacing: SpacingState(spacing: nil, padding: nil, preset: .macOSDefault, original: nil), spacingWorks: false)
        let checks = HidingDiagnostics.menuBarChecks(state) + layout
            + HidingDiagnostics.unattachedIconChecks(["com.example.one"], engine: status(), names: [:])
            + HidingDiagnostics.stuckBarChecks(notRecovered: true)
        let blocks = HidingDiagnostics.blocks(engine: status(), inventory: state)
        let text = DiagnosticsText.render(checks: checks, blocks: blocks, probes: [:], home: "/Users/someone",
                                          timeZone: TimeZone(identifier: "UTC")!)
        #expect(!text.contains("below"))
        #expect(!text.contains("Try Refresh menu bar"))
        let json = DiagnosticsText.json(checks: checks, blocks: blocks, probes: [:], home: "/Users/someone")
        #expect(!String(decoding: try JSONEncoder().encode(json), as: UTF8.self).contains("below"))
        for problem in everyProblem {
            #expect(text.contains(problem.message))
        }
    }

    @Test func nothingReadYetIsUnknown() {
        let checks = HidingDiagnostics.menuBarChecks(nil)
        #expect(checks == [DiagnosticsCheck(title: "Menu bar", status: .unknown, detail: "Not read yet.")])
    }

    // MARK: Ways of hiding

    @Test func everyEngineHasALineAndAMissingOneIsNotCheckedYet() {
        let lines = HidingDiagnostics.engineLines(status(availability: [.allowlist: "available", .approvals: "broken: the list changed"]))
        #expect(lines == ["Allowlist: available", "System Settings switches: broken: the list changed", "Wide spacer: not checked yet"])
        #expect(HidingDiagnostics.engineLines(nil) == ["Allowlist: not checked yet", "System Settings switches: not checked yet",
                                                      "Wide spacer: not checked yet"])
        #expect(HidingDiagnostics.engineLines(status()).count == HidingEngineKind.allCases.count)
    }

    @Test func aKindOnlyTheReasonsKnowIsStillSaid() {
        let lines = HidingDiagnostics.engineLines(status(unavailable: [.approvals: "choose the file"]))
        #expect(lines[1] == "System Settings switches: can't be used: choose the file")
    }

    @Test func whatHidingChangesIsTheThreeNotes() {
        #expect(HidingDiagnostics.whatHidingChanges == [EngineNotes.sideEffects, EngineNotes.clockNote, EngineNotes.crashNote])
    }

    // MARK: An icon macOS doesn't tie to its app

    private let cantTell = "macOS can't tell which app this icon belongs to"
    private let switchesUsable = [HidingEngineKind.approvals: "available"]

    @Test func unattachedRowNamesTheAppWithTheWorkaround() {
        let checks = HidingDiagnostics.unattachedIconChecks(["com.example.one", "com.example.two"], engine: status(),
                                                            names: ["com.example.one": "Zed", "com.example.two": "Alpha"])
        // By name, not by bundle ID: Alpha before Zed.
        #expect(checks.map(\.title) == ["Menu bar icon", "Menu bar icon"])
        #expect(checks.map(\.status) == [.warning, .warning])
        #expect(checks.map(\.detail) == [
            "Alpha: \(cantTell), so it's hidden whenever anything is hidden. To have it shown and hidden with its section, choose System Settings switches in Settings › Advanced › Hiding method.",
            "Zed: \(cantTell), so it's hidden whenever anything is hidden. To have it shown and hidden with its section, choose System Settings switches in Settings › Advanced › Hiding method.",
        ])
    }

    @Test func copiedReportUsesTheBundleID() {
        let checks = HidingDiagnostics.unattachedIconChecks(["com.example.one"], engine: status(), names: [:])
        #expect(checks.first?.detail.hasPrefix("com.example.one: \(cantTell)") == true)
        // A name the pane knows is never in what the report copies, which passes none.
        #expect(checks.first?.detail.contains("Zed") == false)
    }

    @Test func switchesUnusableSaysWhy() {
        let engine = status(unavailable: [.approvals: "Choose the “Allow in the Menu Bar” file in Settings › Permissions"])
        let checks = HidingDiagnostics.unattachedIconChecks(["com.example.one"], engine: engine, names: ["com.example.one": "One"])
        #expect(checks.map(\.status) == [.warning])
        #expect(checks.first?.detail == "One: \(cantTell), so it's hidden whenever anything is hidden. System Settings switches would show and hide it with its section, but can't be used now. Choose the “Allow in the Menu Bar” file in Settings › Permissions.")
    }

    @Test func switchesInUseIsOkAndSaysRefreshClearsIt() {
        let engine = status(kind: .approvals, reason: "x")
        let report = HidingDiagnostics.unattachedIconChecks(["com.example.one"], engine: engine, names: ["com.example.one": "One"])
        #expect(report.map(\.status) == [.ok])
        #expect(report.first?.detail == "One: \(cantTell). System Settings switches are in use, so it's shown and hidden with its section. If you've fixed the app, choose Refresh Menu Bar.")
        let pane = HidingDiagnostics.unattachedIconChecks(["com.example.one"], engine: engine, names: ["com.example.one": "One"],
                                                          suggestingRefresh: true)
        #expect(pane.first?.detail == "One: \(cantTell). System Settings switches are in use, so it's shown and hidden with its section. If you've fixed the app, try Refresh menu bar below.")
    }

    @Test func noRowUnderTheSpacer() {
        let spacer = status(kind: .spacer, reason: "x", degraded: true)
        #expect(HidingDiagnostics.unattachedIconChecks(["com.example.one"], engine: spacer, names: [:]).isEmpty)
        // Nor with nothing to say, or nothing known of the engine.
        #expect(HidingDiagnostics.unattachedIconChecks([], engine: status(), names: [:]).isEmpty)
        #expect(HidingDiagnostics.unattachedIconChecks(["com.example.one"], engine: nil, names: [:]).isEmpty)
    }

    @Test func stuckBarRowIsAWarningUntilTheBarIsWholeOrAResetIsDone() {
        #expect(HidingDiagnostics.stuckBarChecks(notRecovered: false).isEmpty)
        let checks = HidingDiagnostics.stuckBarChecks(notRecovered: true)
        #expect(checks.map(\.title) == ["Menu bar"])
        #expect(checks.map(\.status) == [.warning])
        #expect(checks.map(\.detail) == ["The menu bar didn't come back after a change of displays. Choose Reset."])
    }
}
