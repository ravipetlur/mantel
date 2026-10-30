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

    @Test func anErrorBeatsTheSpacerWarning() {
        let check = HidingDiagnostics.hidingMethodCheck(status(kind: .spacer, degraded: true, lastError: "Wide spacer couldn't hide icons: x."))
        #expect(check.status == .problem)
    }

    // MARK: Menu bar

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
        let text = DiagnosticsText.render(checks: checks, home: "/Users/someone")
        #expect(!text.contains("below"))
        #expect(!text.contains("Try Refresh menu bar"))
        let json = DiagnosticsText.json(checks: checks, home: "/Users/someone")
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
        let text = DiagnosticsText.render(checks: checks, blocks: blocks, home: "/Users/someone")
        #expect(!text.contains("below"))
        #expect(!text.contains("Try Refresh menu bar"))
        let json = DiagnosticsText.json(checks: checks, blocks: blocks, home: "/Users/someone")
        #expect(!String(decoding: try JSONEncoder().encode(json), as: UTF8.self).contains("below"))
        for problem in everyProblem {
            #expect(text.contains(problem.message))
        }
    }

    // MARK: Ways of hiding

    // MARK: An icon macOS doesn't tie to its app

    private let cantTell = "macOS can't tell which app this icon belongs to"
    private let switchesUsable = [HidingEngineKind.approvals: "available"]

    @Test func copiedReportUsesTheBundleID() {
        let checks = HidingDiagnostics.unattachedIconChecks(["com.example.one"], engine: status(), names: [:])
        #expect(checks.first?.detail.hasPrefix("com.example.one: \(cantTell)") == true)
        // A name the pane knows is never in what the report copies, which passes none.
        #expect(checks.first?.detail.contains("Zed") == false)
    }

    @Test func noRowUnderTheSpacer() {
        let spacer = status(kind: .spacer, reason: "x", degraded: true)
        #expect(HidingDiagnostics.unattachedIconChecks(["com.example.one"], engine: spacer, names: [:]).isEmpty)
        // Nor with nothing to say, or nothing known of the engine.
        #expect(HidingDiagnostics.unattachedIconChecks([], engine: status(), names: [:]).isEmpty)
        #expect(HidingDiagnostics.unattachedIconChecks(["com.example.one"], engine: nil, names: [:]).isEmpty)
    }
}
