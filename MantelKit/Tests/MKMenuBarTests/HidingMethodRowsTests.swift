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

    @Test func theTwoWaysAreInOrderWithTheirWords() {
        let rows = HidingMethodRows.rows(engine: status())
        #expect(rows.map(\.choice) == [.automatic, .systemSettingsSwitches])
        #expect(rows.map(\.title) == ["Automatic", "System Settings switches"])
        #expect(rows.map(\.caption) == [
            "Uses macOS's allowlist, and falls back by itself if that stops working.",
            "Turns apps' switches off in System Settings › Menu Bar. Slower, but system indicators stay visible.",
        ])
        #expect(rows.allSatisfy { $0.isEnabled })
        #expect(rows.map(\.id) == HidingMethodChoice.allCases.filter(\.isOffered))
    }

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

    @Test func titlesAreTheEnginesOwnNames() {
        let rows = HidingMethodRows.rows(engine: nil)
        #expect(row(.systemSettingsSwitches, in: rows)?.title == HidingEngineKind.approvals.title)
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

    @Test func aReasonThatEndsInAFullStopDoesNotDoubleIt() {
        let rows = HidingMethodRows.rows(engine: status(unavailable: [.approvals: "choose the file in Settings › Permissions.  "]))
        #expect(row(.systemSettingsSwitches, in: rows)?.caption.hasSuffix("Choose the file in Settings › Permissions.") == true)
        #expect(row(.systemSettingsSwitches, in: rows)?.caption.hasSuffix("..") == false)
    }

    @Test func aFirstWordWithACapitalOfItsOwnIsLeftAsWritten() {
        #expect(HidingMethodRows.sentence("macOS changed the list") == "macOS changed the list.")
        #expect(HidingMethodRows.sentence("macOS's allowlist has changed (x)") == "macOS's allowlist has changed (x).")
        #expect(HidingMethodRows.sentence("the list changed") == "The list changed.")
        #expect(HidingMethodRows.sentence("  ") == "")
        // A reason with nothing in it leaves the caption as it was, and the way is still off.
        let rows = HidingMethodRows.rows(engine: status(unavailable: [.approvals: " "]))
        #expect(row(.systemSettingsSwitches, in: rows)?.caption == HidingMethodRows.switchesCaption)
        #expect(row(.systemSettingsSwitches, in: rows)?.isEnabled == false)
    }

    @Test func automaticIsNeverDisabled() {
        let everythingBroken = status(unavailable: [.allowlist: "a", .approvals: "b", .spacer: "c"])
        #expect(row(.automatic, in: HidingMethodRows.rows(engine: everythingBroken))?.isEnabled == true)
        #expect(row(.automatic, in: HidingMethodRows.rows(engine: everythingBroken))?.caption == HidingMethodRows.automaticCaption)
        // Not even when its own engine, the allowlist, is the one that can't be used: it falls back by itself.
        #expect(row(.automatic, in: HidingMethodRows.rows(engine: status(unavailable: [.allowlist: "x"])))?.isEnabled == true)
        #expect(row(.automatic, in: HidingMethodRows.rows(engine: nil))?.isEnabled == true)
    }

    @Test func aKindMissingFromStatusIsNotAnError() {
        // A status that says nothing of an engine (it wasn't asked, or the status is older than the field) leaves its way open.
        let empty = status(availability: [:], unavailable: [:])
        #expect(HidingMethodRows.rows(engine: empty).allSatisfy { $0.isEnabled })
        let onlyTheAllowlist = status(availability: [.allowlist: "available"], unavailable: [:])
        #expect(HidingMethodRows.rows(engine: onlyTheAllowlist).allSatisfy { $0.isEnabled })
        // And no status at all (nothing read yet) is the same.
        #expect(HidingMethodRows.rows(engine: nil).allSatisfy { $0.isEnabled })
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

    @Test func nowUsingForTheSpacerSaysHowItWorks() {
        // The spacer is in use only because nothing else can be: the line says why, and then what the person does about it.
        let reason = "Allowlist can't be used (it isn't set up), so Mantel uses Wide spacer."
        let spacer = status(kind: .spacer, reason: reason, degraded: true, decidedFor: .automatic)
        let line = HidingMethodRows.nowUsing(spacer)
        #expect(line == "Now using: Wide spacer. \(reason) It hides only the icons left of Mantel's divider, the thin line that shows while icons are revealed. ⌘-drag icons to its left.")
        // No other engine's line says it.
        #expect(HidingMethodRows.nowUsing(status(kind: .allowlist))?.contains("divider") == false)
        #expect(HidingMethodRows.nowUsing(status(kind: .approvals))?.contains("divider") == false)

        // And it is the line the pane shows, with Automatic still the choice and no switch under way.
        let shown = HidingMethodRows.presentation(method: .automatic, engine: spacer)
        #expect(shown.nowUsing == line)
        #expect(!shown.isSwitching)
        #expect(shown.rows.allSatisfy { $0.isEnabled })
    }

    @Test func nowUsingIsTheTitleAndTheReasonExactly() {
        let line = HidingMethodRows.nowUsing(status(kind: .approvals, reason: "Chosen in Settings › Advanced."))
        #expect(line == "Now using: System Settings switches. Chosen in Settings › Advanced.")
        #expect(HidingMethodRows.nowUsing(status()) == "Now using: Allowlist. Chosen automatically: macOS's allowlist works.")
        #expect(HidingMethodRows.nowUsing(nil) == nil)
    }

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

    @Test func theLineSaysSwitchingUntilTheEngineMatches() {
        let before = status(kind: .allowlist, decidedFor: .automatic)
        let switching = HidingMethodRows.presentation(method: .systemSettingsSwitches, engine: before)
        #expect(switching.switching == "Switching to System Settings switches…")
        #expect(switching.nowUsing == "Now using: Allowlist. Chosen automatically: macOS's allowlist works.",
                "the line it replaces is kept, for the room")

        // The new engine is in charge, but the switch isn't done (the old one is still being taken down): still switching.
        let midway = status(kind: .approvals, reason: "Chosen in Settings › Advanced.", decidedFor: .automatic)
        #expect(HidingMethodRows.presentation(method: .systemSettingsSwitches, engine: midway).isSwitching)

        // Settled: the engine is the one the choice names, and the line is the engine's own words.
        let after = status(kind: .approvals, reason: "Chosen in Settings › Advanced.", decidedFor: .systemSettingsSwitches)
        let settled = HidingMethodRows.presentation(method: .systemSettingsSwitches, engine: after)
        #expect(settled.switching == nil)
        #expect(settled.nowUsing == "Now using: System Settings switches. Chosen in Settings › Advanced.")
        #expect(settled.rows.allSatisfy { $0.isEnabled })

        // Going back says the choice's own name.
        #expect(HidingMethodRows.presentation(method: .automatic, engine: after).switching == "Switching to Automatic…")
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

    @Test func aResetsTeardownStatusOnAFallbackEngineShowsNoSpinner() async {
        // The allowlist fails out and the switches take over (Automatic is still the choice). Then a reset takes everything down: the
        // controller forgets what it chose for, and the engine that stays named is the fallback, which isn't the allowlist Automatic
        // names. That is not a switch under way: no spinner, and the choices are open.
        let log = CallLog()
        let allowlist = FakeEngine(.allowlist, log: log)
        let controller = HidingController(
            engines: [.allowlist: allowlist, .approvals: FakeEngine(.approvals, log: log), .spacer: FakeEngine(.spacer, log: log)],
            clock: FakeClock(), confirm: { _ in .seen }, note: { _ in })
        await controller.choose(method: .automatic)
        allowlist.failNext(-1)
        let plan = EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.b"])
        for _ in 0..<3 { await controller.apply(plan) }
        let failedOver = await controller.status()
        #expect(failedOver.kind == .approvals)
        #expect(failedOver.decidedFor == .automatic)

        await controller.tearDown()
        let afterReset = await controller.status()
        #expect(afterReset.kind == .approvals, "the engine it last named")
        #expect(afterReset.decidedFor == nil, "and nothing it was chosen for")

        let shown = HidingMethodRows.presentation(method: .automatic, engine: afterReset)
        #expect(!shown.isSwitching)
        #expect(shown.switching == nil)
        #expect(shown.rows.allSatisfy { $0.isEnabled })
    }

    @Test func aFailedSwitchShowsTheReason() {
        // The switches were chosen and can't be used: the engine settled on the allowlist. That is not a switch under way: the choices
        // are open, and the line says why, as it always has.
        let reason = "System Settings switches can't be used (no list), so Mantel uses Allowlist."
        let settled = status(kind: .allowlist, reason: reason, availability: [.approvals: "broken: no list"],
                             unavailable: [.approvals: "no list"], decidedFor: .systemSettingsSwitches)
        let shown = HidingMethodRows.presentation(method: .systemSettingsSwitches, engine: settled)
        #expect(!shown.isSwitching)
        #expect(shown.switching == nil)
        #expect(shown.nowUsing == "Now using: Allowlist. \(reason)")
        #expect(shown.rows.first { $0.choice == .systemSettingsSwitches }?.isEnabled == false, "its own reason is where it always was")
        #expect(shown.rows.first { $0.choice == .automatic }?.isEnabled == true)
    }

    // MARK: Advanced's other words

    @Test func theNoRoomChoicesHaveTheirWords() {
        #expect(NoRoomPolicy.allCases.map(AdvancedCopy.title(for:)) == [
            "Open the second bar", "Hide some shown icons to make room", "Hide the front app's menus",
        ])
        #expect(AdvancedCopy.caption(for: .secondBar) == "Hidden icons that don't fit open in a bar of their own under the menu bar.")
        #expect(AdvancedCopy.caption(for: .swap) == "Mantel hides shown icons from the right until the revealed ones fit, and brings them back afterwards.")
        #expect(AdvancedCopy.caption(for: .hideAppMenus)
            == "Mantel briefly becomes the front app so its short menu leaves room. Its Dock icon shows for a moment.")
    }

    @Test func allowingTheClockAsksFirstAndTurningItOffNever() {
        #expect(AdvancedCopy.asksBeforeAllowingClock(turningOn: true))
        #expect(!AdvancedCopy.asksBeforeAllowingClock(turningOn: false))
        #expect(AdvancedCopy.allowClockTitle == "Allow hiding the clock and Control Center?")
        #expect(AdvancedCopy.allowClockText
            == "The volume and brightness pop-ups and other system controls can stop working while they're hidden. You can turn this off at any time.")
        #expect(AdvancedCopy.allowClockConfirm == "Allow")
        #expect(AdvancedCopy.allowClockCancel == "Cancel")
    }

    // MARK: The status carries the reasons

    @Test func statusDecodesWithoutReasonsAsEmpty() throws {
        // A status written before the reasons were kept.
        let old = #"{"kind":"allowlist","reason":"Why.","degraded":false,"availability":{"allowlist":"available"}}"#
        let decoded = try JSONDecoder().decode(EngineStatus.self, from: Data(old.utf8))
        #expect(decoded.unavailableReasons.isEmpty)
        #expect(decoded.decidedFor == nil)
        #expect(decoded.lastError == nil)
        #expect(decoded.availability == [.allowlist: "available"])
    }

    @Test func statusRoundTripsItsReasons() throws {
        let original = status(kind: .spacer, degraded: true, availability: [.approvals: "needs permission: choose the file"],
                              unavailable: [.approvals: "choose the file"], lastError: "It broke.", decidedFor: .automatic)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(EngineStatus.self, from: data) == original)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["unavailableReasons"] as? [String: String])?["approvals"] == "choose the file")
        #expect(object["decidedFor"] as? String == "automatic")
    }
}
