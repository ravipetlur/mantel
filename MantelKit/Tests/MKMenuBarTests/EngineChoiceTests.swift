import Foundation
import MKCore
import Testing

@testable import MKMenuBar

@Suite("Engine choice", .timeLimit(.minutes(1)))
struct EngineChoiceTests {
    private static let ok = EngineAvailability.available
    private static let everythingWorks: [HidingEngineKind: EngineAvailability] = [.allowlist: ok, .approvals: ok, .spacer: ok]

    private static func available(_ broken: [HidingEngineKind: EngineAvailability] = [:]) -> [HidingEngineKind: EngineAvailability] {
        everythingWorks.merging(broken) { _, new in new }
    }

    private static func inputs(_ method: HidingMethodChoice = .automatic, call: Bool = false, keepMic: Bool = false,
                               availability: [HidingEngineKind: EngineAvailability] = everythingWorks,
                               failedOut: Set<HidingEngineKind> = []) -> EngineChoiceInputs {
        EngineChoiceInputs(method: method, callActive: call, keepMicVisibleDuringCalls: keepMic, availability: availability, failedOut: failedOut)
    }

    /// One row of the table: what is asked, and the engine and the reason it gets.
    struct Row: CustomTestStringConvertible, Sendable {
        let name: String
        let inputs: EngineChoiceInputs
        let kind: HidingEngineKind
        let reason: String

        var testDescription: String { name }
    }

    private static let appsFolder = EngineAvailability.broken("Mantel has to run from the Applications folder for this")
    private static let needsFile = EngineAvailability.needsPermission("Choose the “Allow in the Menu Bar” file in Settings › Permissions")
    private static let changed = EngineAvailability.broken("macOS changed the “Allow in the Menu Bar” list, so Mantel can't edit it")

    static let rows: [Row] = [
        Row(name: "a call keeps the mic visible", inputs: inputs(call: true, keepMic: true), kind: .approvals,
            reason: "A call is active, so the mic indicator stays visible."),
        Row(name: "the call row comes before the person's choice", inputs: inputs(.wideSpacer, call: true, keepMic: true), kind: .approvals,
            reason: "A call is active, so the mic indicator stays visible."),
        Row(name: "the person chose the switches", inputs: inputs(.systemSettingsSwitches), kind: .approvals, reason: "Chosen in Settings › Advanced."),
        Row(name: "the person chose the spacer", inputs: inputs(.wideSpacer), kind: .spacer, reason: "Chosen in Settings › Advanced."),
        Row(name: "automatic", inputs: inputs(.automatic), kind: .allowlist, reason: "Chosen automatically: macOS's allowlist works."),
        Row(name: "automatic, the allowlist is broken", inputs: inputs(availability: available([.allowlist: appsFolder])), kind: .approvals,
            reason: "Allowlist can't be used (Mantel has to run from the Applications folder for this), so Mantel uses System Settings switches."),
        Row(name: "automatic, neither the allowlist nor the switches work",
            inputs: inputs(availability: available([.allowlist: appsFolder, .approvals: needsFile])), kind: .spacer,
            reason: "Allowlist can't be used (Mantel has to run from the Applications folder for this), so Mantel uses Wide spacer."),
        Row(name: "the switches chosen, and broken: the allowlist, not the spacer", inputs: inputs(.systemSettingsSwitches, availability: available([.approvals: changed])),
            kind: .allowlist,
            reason: "System Settings switches can't be used (macOS changed the “Allow in the Menu Bar” list, so Mantel can't edit it), so Mantel uses Allowlist."),
        Row(name: "the switches chosen, and neither they nor the allowlist work",
            inputs: inputs(.systemSettingsSwitches, availability: available([.allowlist: appsFolder, .approvals: needsFile])), kind: .spacer,
            reason: "System Settings switches can't be used (Choose the “Allow in the Menu Bar” file in Settings › Permissions), so Mantel uses Wide spacer."),
        Row(name: "the spacer chosen, and broken: the allowlist", inputs: inputs(.wideSpacer, availability: available([.spacer: .broken("it can't draw")])),
            kind: .allowlist, reason: "Wide spacer can't be used (it can't draw), so Mantel uses Allowlist."),
        Row(name: "the spacer chosen, and the allowlist broken: the switches",
            inputs: inputs(.wideSpacer, availability: available([.spacer: .broken("it can't draw"), .allowlist: appsFolder])), kind: .approvals,
            reason: "Wide spacer can't be used (it can't draw), so Mantel uses System Settings switches."),
        Row(name: "automatic, the allowlist failed out", inputs: inputs(failedOut: [.allowlist]), kind: .approvals,
            reason: "Allowlist can't be used (it failed 3 times in a row; Refresh Menu Bar tries it again), so Mantel uses System Settings switches."),
    ]

    @Test(arguments: rows)
    func theTableDecides(row: Row) {
        let choice = EngineChoice.decide(row.inputs)
        #expect(choice.kind == row.kind)
        #expect(choice.reason == row.reason)
    }

    // MARK: The named rows

    @Test func automaticPicksAllowlist() {
        let choice = EngineChoice.decide(Self.inputs())
        #expect(choice == EngineChoice(kind: .allowlist, reason: "Chosen automatically: macOS's allowlist works."))
        // Whatever the other two say, an allowlist that works is the automatic choice.
        let others = Self.inputs(availability: Self.available([.approvals: Self.changed, .spacer: Self.appsFolder]))
        #expect(EngineChoice.decide(others).kind == .allowlist)
    }

    @Test func automaticFallsToApprovalsThenSpacer() {
        let first = EngineChoice.decide(Self.inputs(availability: Self.available([.allowlist: Self.appsFolder])))
        #expect(first.kind == .approvals)
        let second = EngineChoice.decide(Self.inputs(availability: Self.available([.allowlist: Self.appsFolder, .approvals: Self.needsFile])))
        #expect(second.kind == .spacer)
        // A switch that works but that isn't granted yet is no engine: needs permission is unavailable too.
        #expect(Self.needsFile.isAvailable == false)
    }

    @Test func savedChoiceThatCantBeUsedFallsToAutomatic() {
        // The switches, when chosen and unusable, are never a silent fall through to the spacer: Automatic's chain decides, and the
        // allowlist, when it works, is the first of it.
        let broken = Self.inputs(.systemSettingsSwitches, availability: Self.available([.approvals: Self.needsFile]))
        let choice = EngineChoice.decide(broken)
        #expect(choice.kind == .allowlist)
        #expect(choice.reason == "System Settings switches can't be used (Choose the “Allow in the Menu Bar” file in Settings › Permissions), so Mantel uses Allowlist.")
        // The same when it failed out instead of being unavailable.
        #expect(EngineChoice.decide(Self.inputs(.systemSettingsSwitches, failedOut: [.approvals])).kind == .allowlist)
        // And the spacer, when chosen and unusable.
        #expect(EngineChoice.decide(Self.inputs(.wideSpacer, availability: Self.available([.spacer: Self.changed]))).kind == .allowlist)
        #expect(EngineChoice.decide(Self.inputs(.wideSpacer, failedOut: [.spacer])).kind == .allowlist)
        // The chain skips what can't be used: the allowlist is gone too, so the next is the switches (for the spacer) or the spacer (for them).
        let noAllowlist = Self.available([.allowlist: Self.appsFolder])
        #expect(EngineChoice.decide(Self.inputs(.wideSpacer, availability: noAllowlist.merging([.spacer: Self.changed]) { _, new in new })).kind == .approvals)
        #expect(EngineChoice.decide(Self.inputs(.systemSettingsSwitches, availability: noAllowlist.merging([.approvals: Self.needsFile]) { _, new in new })).kind == .spacer)
        // A choice that works is the choice, whatever the others say.
        let working = Self.inputs(.systemSettingsSwitches, availability: Self.available([.allowlist: Self.appsFolder]))
        #expect(EngineChoice.decide(working) == EngineChoice(kind: .approvals, reason: "Chosen in Settings › Advanced."))
    }

    @Test func theSpacerIsUsedOnlyWhenNothingElseCan() {
        // Settings doesn't offer it, so it is only ever the last of Automatic's chain.
        for method in [HidingMethodChoice.automatic, .systemSettingsSwitches] {
            #expect(EngineChoice.decide(Self.inputs(method)).kind != .spacer, "\(method): everything works")
            // Either of the others being usable is enough to keep it out.
            let noAllowlist = Self.available([.allowlist: Self.appsFolder])
            #expect(EngineChoice.decide(Self.inputs(method, availability: noAllowlist)).kind == .approvals, "\(method): the switches work")
            let noSwitches = Self.available([.approvals: Self.needsFile])
            #expect(EngineChoice.decide(Self.inputs(method, availability: noSwitches)).kind == .allowlist, "\(method): the allowlist works")
            #expect(EngineChoice.decide(Self.inputs(method, failedOut: [.allowlist])).kind == .approvals, "\(method): the allowlist failed out")
            #expect(EngineChoice.decide(Self.inputs(method, failedOut: [.approvals])).kind == .allowlist, "\(method): the switches failed out")

            // Neither can be used: the spacer hides, and the reason says why the others didn't.
            let neither = Self.available([.allowlist: Self.appsFolder, .approvals: Self.needsFile])
            let last = EngineChoice.decide(Self.inputs(method, availability: neither))
            #expect(last.kind == .spacer, "\(method)")
            #expect(last.reason.hasSuffix("so Mantel uses Wide spacer."), "\(method): \(last.reason)")
        }
        // A saved file can't ask for it either: what it says is read as Automatic (`HidingSettings`), which only gets here when nothing
        // else works.
        let decoded = try? JSONDecoder().decode(HidingSettings.self, from: Data(#"{"method":"wideSpacer"}"#.utf8))
        #expect(decoded.map { EngineChoice.decide(Self.inputs($0.method)).kind } == .allowlist)
    }

    @Test func spacerChoiceIsSpacer() {
        #expect(EngineChoice.decide(Self.inputs(.wideSpacer)).kind == .spacer)
        // Nothing can hide icons: the spacer stays in charge, and is tried again.
        let nothing = Self.available([.allowlist: Self.appsFolder, .approvals: Self.needsFile, .spacer: .broken("it can't draw")])
        for method in HidingMethodChoice.allCases {
            let choice = EngineChoice.decide(Self.inputs(method, availability: nothing))
            #expect(choice.kind == .spacer, "\(method)")
            #expect(choice.reason == "Wide spacer can't be used (it can't draw), and nothing else can hide icons, so Mantel keeps trying it.", "\(method)")
        }
        let failedOut = EngineChoice.decide(Self.inputs(.wideSpacer, failedOut: [.spacer, .allowlist, .approvals]))
        #expect(failedOut.kind == .spacer)
        #expect(failedOut.reason == "Wide spacer can't be used (it failed 3 times in a row; Refresh Menu Bar tries it again), and nothing else can hide icons, so Mantel keeps trying it.")
    }

    @Test(arguments: [(call: false, keep: false, kind: HidingEngineKind.allowlist), (true, false, .allowlist), (false, true, .allowlist), (true, true, .approvals)])
    func callRowNeedsCallAndSetting(call: Bool, keep: Bool, kind: HidingEngineKind) {
        #expect(EngineChoice.decide(Self.inputs(call: call, keepMic: keep)).kind == kind)
        // And the switches that can't be used: the row doesn't apply, and the rows below it decide.
        let broken = Self.inputs(call: call, keepMic: keep, availability: Self.available([.approvals: Self.changed]))
        #expect(EngineChoice.decide(broken).kind == .allowlist)
        let failed = Self.inputs(call: call, keepMic: keep, failedOut: [.approvals])
        #expect(EngineChoice.decide(failed).kind == .allowlist)
    }

    @Test func failedOutCountsAsUnavailable() {
        // An engine that is available and has failed out is as good as one that isn't.
        let allowlist = EngineChoice.decide(Self.inputs(failedOut: [.allowlist]))
        #expect(allowlist.kind == .approvals)
        let both = EngineChoice.decide(Self.inputs(failedOut: [.allowlist, .approvals]))
        #expect(both.kind == .spacer)
        #expect(both.reason == "Allowlist can't be used (it failed 3 times in a row; Refresh Menu Bar tries it again), so Mantel uses Wide spacer.")
        // A failed-out engine that also reports why it can't be used says that.
        let broken = EngineChoice.decide(Self.inputs(availability: Self.available([.allowlist: Self.appsFolder]), failedOut: [.allowlist]))
        #expect(broken.reason.contains("Mantel has to run from the Applications folder for this"))
        // And the choice made again without the failed-out engine is the one that was asked for, when that is another.
        #expect(EngineChoice.decide(Self.inputs(.systemSettingsSwitches, failedOut: [.allowlist])).kind == .approvals)
    }

    @Test func reasonsAreExact() {
        let reasons: Set<String> = [
            EngineChoice.decide(Self.inputs(call: true, keepMic: true)).reason,
            EngineChoice.decide(Self.inputs(.systemSettingsSwitches)).reason,
            EngineChoice.decide(Self.inputs(.wideSpacer)).reason,
            EngineChoice.decide(Self.inputs()).reason,
            EngineChoice.decide(Self.inputs(failedOut: [.allowlist])).reason,
        ]
        #expect(reasons == [
            "A call is active, so the mic indicator stays visible.",
            "Chosen in Settings › Advanced.",
            "Chosen automatically: macOS's allowlist works.",
            "Allowlist can't be used (it failed 3 times in a row; Refresh Menu Bar tries it again), so Mantel uses System Settings switches.",
        ])
        #expect(HidingEngineKind.allCases.map(\.title) == ["Allowlist", "System Settings switches", "Wide spacer"])
    }

    @Test func anEngineThatIsMissingCantBeChosen() {
        let missing = EngineChoiceInputs(method: .automatic, availability: [.approvals: .available, .spacer: .available])
        let choice = EngineChoice.decide(missing)
        #expect(choice.kind == .approvals)
        #expect(choice.reason == "Allowlist can't be used (it isn't set up), so Mantel uses System Settings switches.")
    }

    // MARK: What is said about an engine

    @Test func availabilityIsSaidInWords() {
        #expect(EngineAvailability.available.statusText == "available")
        #expect(Self.needsFile.statusText == "needs permission: Choose the “Allow in the Menu Bar” file in Settings › Permissions")
        #expect(EngineAvailability.broken("x").statusText == "broken: x")
        #expect(EngineAvailability.available.reason == nil)
    }

    @Test func errorsSayWhatHappened() {
        #expect(HidingError.notSettled(.approvals, "macOS hadn't caught up").errorDescription == "System Settings switches couldn't hide icons: macOS hadn't caught up.")
        #expect(HidingError.unavailable(.approvals, "the file isn't chosen").errorDescription == "System Settings switches can't be used: the file isn't chosen.")
        #expect(HidingError.failed(.allowlist, "macOS said no").errorDescription == "Allowlist couldn't hide icons: macOS said no.")
        // A reason that ends in a full stop doesn't make two.
        #expect(HidingError.failed(.allowlist, "macOS said no.").errorDescription == "Allowlist couldn't hide icons: macOS said no.")
        #expect(HidingError.failed(.spacer, "x") != HidingError.unavailable(.spacer, "x"))
    }

    @Test func statusIsCodableWithEngineKeys() throws {
        let status = EngineStatus(kind: .spacer, reason: "why", degraded: true,
                                  availability: [.allowlist: "available", .spacer: "broken: x"], lastError: nil)
        let data = try JSONEncoder().encode(status)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["availability"] as? [String: String])?["allowlist"] == "available", "a dictionary keyed by engine is an object")
        #expect(try JSONDecoder().decode(EngineStatus.self, from: data) == status)
    }

    // MARK: An icon macOS doesn't tie to its app

    private static func unattached(_ apps: Set<String>, _ method: HidingMethodChoice = .automatic, call: Bool = false, keepMic: Bool = false,
                                   availability: [HidingEngineKind: EngineAvailability] = everythingWorks,
                                   failedOut: Set<HidingEngineKind> = []) -> EngineChoice {
        EngineChoice.decide(EngineChoiceInputs(method: method, callActive: call, keepMicVisibleDuringCalls: keepMic,
                                               availability: availability, failedOut: failedOut, unattachedShownApps: apps))
    }

    @Test func automaticUsesSwitchesWhileAShownAppIsUnattached() {
        let one = Self.unattached(["com.example.one"])
        #expect(one.kind == .approvals)
        #expect(one.reason == "1 app in Shown has an icon macOS can't tie to it, so Mantel uses System Settings switches, which keep it shown.")
        let two = Self.unattached(["com.example.one", "com.example.two"])
        #expect(two.kind == .approvals)
        #expect(two.reason == "2 apps in Shown have icons macOS can't tie to them, so Mantel uses System Settings switches, which keep them shown.")
        // Nothing unattached: the allowlist, as before.
        #expect(Self.unattached([]).kind == .allowlist)
    }

    @Test func explicitChoicesAreNeverChanged() {
        let apps: Set<String> = ["com.example.one"]
        #expect(Self.unattached(apps, .wideSpacer).kind == .spacer)
        #expect(Self.unattached(apps, .wideSpacer).reason == "Chosen in Settings › Advanced.")
        #expect(Self.unattached(apps, .systemSettingsSwitches).reason == "Chosen in Settings › Advanced.")
        // The switches chosen and broken: Automatic's chain, as without any unattached app.
        let broken = Self.available([.approvals: Self.changed])
        #expect(Self.unattached(apps, .systemSettingsSwitches, availability: broken)
            == EngineChoice.decide(Self.inputs(.systemSettingsSwitches, availability: broken)))
    }

    @Test func switchesUnusableKeepTheAllowlistNotTheSpacer() {
        let apps: Set<String> = ["com.example.one"]
        // Unavailable: Automatic's own chain decides, and the allowlist stays in charge.
        let unavailable = Self.available([.approvals: Self.needsFile])
        #expect(Self.unattached(apps, availability: unavailable) == EngineChoice.decide(Self.inputs(availability: unavailable)))
        #expect(Self.unattached(apps, availability: unavailable).kind == .allowlist)
        // With the allowlist unusable too, the chain reaches the spacer only as it does without the unattached app.
        let neither = Self.available([.allowlist: Self.appsFolder, .approvals: Self.needsFile])
        #expect(Self.unattached(apps, availability: neither) == EngineChoice.decide(Self.inputs(availability: neither)))
    }

    @Test func failedOutSwitchesFallBackToTheAllowlist() {
        let apps: Set<String> = ["com.example.one"]
        let choice = Self.unattached(apps, failedOut: [.approvals])
        #expect(choice.kind == .allowlist)
        #expect(choice == EngineChoice.decide(Self.inputs(failedOut: [.approvals])))
    }

    @Test func callRowWinsOverUnattached() {
        let choice = Self.unattached(["com.example.one"], call: true, keepMic: true)
        #expect(choice.kind == .approvals)
        #expect(choice.reason == "A call is active, so the mic indicator stays visible.")
    }

    @Test func reasonCountsAppsAndNamesNone() {
        for count in 1...4 {
            let apps = Set((0..<count).map { "com.example.secret\($0)" })
            let reason = Self.unattached(apps).reason
            #expect(!reason.contains("com.example"), "\(reason)")
            #expect(reason.hasPrefix(count == 1 ? "1 app in Shown has" : "\(count) apps in Shown have"))
        }
    }
}
