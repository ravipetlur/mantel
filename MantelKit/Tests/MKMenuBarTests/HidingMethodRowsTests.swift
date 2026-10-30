import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

@Suite("Hiding method rows", .timeLimit(.minutes(1)))
struct HidingMethodRowsTests {
    private func status(kind: HidingEngineKind = .allowlist, reason: String = "Chosen automatically: macOS's allowlist works.",
                        degraded: Bool = false, availability: [HidingEngineKind: String] = [:],
                        unavailable: [HidingEngineKind: String] = [:], lastError: String? = nil,
                        decidedFor: HidingMethodChoice? = nil) -> EngineStatus {
        EngineStatus(kind: kind, reason: reason, degraded: degraded, availability: availability, lastError: lastError,
                     unavailableReasons: unavailable, decidedFor: decidedFor)
    }

    private func row(_ choice: HidingMethodChoice, in rows: [HidingMethodRow]) -> HidingMethodRow? {
        rows.first { $0.choice == choice }
    }

    // MARK: The two ways

    @Test func wideSpacerIsNotOffered() {
        // Whatever the status says of the spacer (in use, usable, or not), Advanced has no choice for it.
        let statuses = [
            status(kind: .spacer, degraded: true, availability: [.spacer: "available"]),
            status(unavailable: [.spacer: "no menu bar is shown"]),
            status(availability: [.spacer: "available"]),
            nil,
        ]
        for engine in statuses {
            let rows = HidingMethodRows.rows(engine: engine)
            #expect(!rows.contains { $0.choice == .wideSpacer })
            #expect(!rows.contains { $0.title == HidingEngineKind.spacer.title })
            #expect(rows.count == 2)
            let presentation = HidingMethodRows.presentation(method: .automatic, engine: engine)
            #expect(!presentation.rows.contains { $0.choice == .wideSpacer })
        }
        // Diagnostics still lists the three ways, with their availability: the status carries all of them.
        let all = status(availability: [.allowlist: "available", .approvals: "available", .spacer: "available"])
        #expect(Set(all.availability.keys) == Set(HidingEngineKind.allCases))
    }

    // MARK: P24: the reason an engine can't be used

    @Test func switchesDisabledWithTheEnginesReason() {
        let reason = "macOS keeps this list in a format Mantel can't edit yet"
        let rows = HidingMethodRows.rows(engine: status(availability: [.approvals: "broken: \(reason)"], unavailable: [.approvals: reason]))
        let switches = row(.systemSettingsSwitches, in: rows)
        #expect(switches?.isEnabled == false)
        // The caption says what the way does, and ends with why it can't be used: capitalised, and ending in a full stop.
        #expect(switches?.caption == "\(HidingMethodRows.switchesCaption) macOS keeps this list in a format Mantel can't edit yet.")
        #expect(switches?.caption.hasSuffix(".") == true)
    }

    @Test func automaticIsNeverDisabled() {
        let everythingBroken = status(unavailable: [.allowlist: "a", .approvals: "b", .spacer: "c"])
        #expect(row(.automatic, in: HidingMethodRows.rows(engine: everythingBroken))?.isEnabled == true)
        #expect(row(.automatic, in: HidingMethodRows.rows(engine: everythingBroken))?.caption == HidingMethodRows.automaticCaption)
        // Not even when its own engine, the allowlist, is the one that can't be used: it falls back by itself.
        #expect(row(.automatic, in: HidingMethodRows.rows(engine: status(unavailable: [.allowlist: "x"])))?.isEnabled == true)
        #expect(row(.automatic, in: HidingMethodRows.rows(engine: nil))?.isEnabled == true)
    }

    @Test func aFailedOutEngineStaysSelectable() async {
        // Three failures in a row fail the allowlist out, which says nothing against choosing it again: it isn't in the reasons.
        let log = CallLog()
        let allowlist = FakeEngine(.allowlist, log: log)
        let approvals = FakeEngine(.approvals, log: log)
        let spacer = FakeEngine(.spacer, log: log)
        let controller = HidingController(
            engines: [.allowlist: allowlist, .approvals: approvals, .spacer: spacer], clock: FakeClock(),
            confirm: { _ in .seen }, note: { _ in })
        await controller.choose(method: .automatic)
        allowlist.failNext(-1)
        let plan = EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.b"])
        for _ in 0..<3 { await controller.apply(plan) }

        let failedOut = await controller.status()
        #expect(failedOut.kind == .approvals, "the allowlist failed out, so the switches are in use")
        #expect(failedOut.unavailableReasons.isEmpty, "failing out isn't being unavailable")
        let rows = HidingMethodRows.rows(engine: failedOut)
        #expect(rows.allSatisfy { $0.isEnabled })
        // "Now using" is where the person is told why.
        #expect(HidingMethodRows.nowUsing(failedOut)?.contains("Allowlist can't be used (it failed 3 times in a row") == true)
    }

    // MARK: Now using

    // MARK: A switch under way

    @Test func aSwitchUnderWayDisablesTheChoices() {
        // The person chose the switches while the allowlist, which was chosen for Automatic, is still in use.
        let status = status(kind: .allowlist, decidedFor: .automatic)
        let settled = HidingMethodRows.presentation(method: .automatic, engine: status)
        #expect(!settled.isSwitching)
        #expect(settled.rows.allSatisfy { $0.isEnabled })

        let switching = HidingMethodRows.presentation(method: .systemSettingsSwitches, engine: status)
        #expect(switching.isSwitching)
        #expect(switching.rows.allSatisfy { !$0.isEnabled }, "none can be chosen meanwhile")
        // The same choices otherwise: the same words, in the same places.
        #expect(switching.rows.map(\.title) == settled.rows.map(\.title))
        #expect(switching.rows.map(\.caption) == settled.rows.map(\.caption))
        #expect(switching.rows.map(\.choice) == settled.rows.map(\.choice))
    }

    @Test func aStatusThatSaysNothingOfItsChoiceIsNotASwitch() {
        // Before the first choice, after a reset took everything down, or older than the field: nothing says a choice is on its way, and
        // none is waited for, whatever engine is in use.
        for method in HidingMethodChoice.allCases {
            for kind in HidingEngineKind.allCases {
                let shown = HidingMethodRows.presentation(method: method, engine: status(kind: kind))
                #expect(!shown.isSwitching, "\(method) with \(kind) in use")
                #expect(shown.switching == nil)
                #expect(shown.rows.allSatisfy { $0.isEnabled })
            }
        }
        // And no status at all shows nothing that is under way.
        let nothing = HidingMethodRows.presentation(method: .systemSettingsSwitches, engine: nil)
        #expect(!nothing.isSwitching)
        #expect(nothing.nowUsing == nil)
        #expect(nothing.rows.allSatisfy { $0.isEnabled })
    }

    // MARK: Advanced's other words

    // MARK: The status carries the reasons
}
