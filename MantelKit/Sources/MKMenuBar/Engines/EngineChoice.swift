import Foundation
import MKCore

/// What decides which engine hides the icons.
public struct EngineChoiceInputs: Sendable, Equatable {
    /// What the person chose in Settings › Advanced.
    public var method: HidingMethodChoice
    /// A call is going on. (False until Mantel knows about calls.)
    public var callActive: Bool
    /// The person asked for the microphone indicator to stay visible during calls. (False until Mantel knows about calls.)
    public var keepMicVisibleDuringCalls: Bool
    public var availability: [HidingEngineKind: EngineAvailability]
    /// The engines that threw three times in a row and are not tried again until Refresh or the next launch.
    public var failedOut: Set<HidingEngineKind>

    public init(method: HidingMethodChoice, callActive: Bool = false, keepMicVisibleDuringCalls: Bool = false,
                availability: [HidingEngineKind: EngineAvailability], failedOut: Set<HidingEngineKind> = []) {
        self.method = method
        self.callActive = callActive
        self.keepMicVisibleDuringCalls = keepMicVisibleDuringCalls
        self.availability = availability
        self.failedOut = failedOut
    }
}

/// The engine to hide with, and why, in words for Diagnostics.
public struct EngineChoice: Sendable, Equatable {
    public let kind: HidingEngineKind
    public let reason: String

    public init(kind: HidingEngineKind, reason: String) {
        self.kind = kind
        self.reason = reason
    }

    /// The Automatic chain: the engines in the order Mantel prefers them, the first that can be used winning. It is what a method the
    /// person chose falls back to when its own engine can't be used, as well as what Automatic itself is. The spacer is the last in it,
    /// and the only way it is used any more: Settings doesn't offer it, so it hides only when neither of the others can be used.
    static let automaticChain: [HidingEngineKind] = [.allowlist, .approvals, .spacer]

    static let chosenInAdvanced = "Chosen in Settings › Advanced."

    /// The first row of this table that applies decides:
    ///
    /// | Situation | Engine |
    /// |---|---|
    /// | a call is active, the mic indicator is to stay visible, and the switches can be used | System Settings switches |
    /// | the person chose System Settings switches | System Settings switches |
    /// | the wide spacer (no longer offered in Settings, and never read from a saved file) | Wide spacer |
    /// | automatic | Allowlist |
    ///
    /// **A method the person chose that can't be used** (its engine isn't available, or is in `failedOut`) is never a silent fall
    /// through to a worse engine: Automatic's chain decides instead (the allowlist, then the switches, then the spacer, skipping any
    /// that can't be used), and the reason says which engine was chosen, why it can't be used, and what Mantel uses instead. This
    /// holds for Automatic itself, whose own engine is the allowlist.
    ///
    /// If nothing in the chain can be used, the spacer stays in charge and Mantel keeps trying it.
    public static func decide(_ inputs: EngineChoiceInputs) -> EngineChoice {
        if inputs.callActive, inputs.keepMicVisibleDuringCalls, usable(.approvals, inputs) {
            return EngineChoice(kind: .approvals, reason: "A call is active, so the mic indicator stays visible.")
        }
        let chosen: HidingEngineKind
        let reason: String
        switch inputs.method {
        case .systemSettingsSwitches:
            (chosen, reason) = (.approvals, chosenInAdvanced)
        case .wideSpacer:
            (chosen, reason) = (.spacer, chosenInAdvanced)
        case .automatic:
            (chosen, reason) = (.allowlist, "Chosen automatically: macOS's allowlist works.")
        }
        if usable(chosen, inputs) { return EngineChoice(kind: chosen, reason: reason) }

        for next in automaticChain where next != chosen && usable(next, inputs) {
            return EngineChoice(kind: next, reason: "\(chosen.title) can't be used (\(unusableReason(chosen, inputs))), so Mantel uses \(next.title).")
        }
        // Nothing works: the last resort stays in charge, and is tried again with the next plan.
        let last = automaticChain.last ?? .spacer
        return EngineChoice(kind: last, reason: "\(last.title) can't be used (\(unusableReason(last, inputs))), and nothing else can hide icons, so Mantel keeps trying it.")
    }

    /// Whether Mantel may use the engine now: it is available, and hasn't failed out.
    static func usable(_ kind: HidingEngineKind, _ inputs: EngineChoiceInputs) -> Bool {
        guard !inputs.failedOut.contains(kind) else { return false }
        return inputs.availability[kind]?.isAvailable ?? false
    }

    /// Why the engine can't be used, as a clause: what it reports, or that it failed three times, or that nothing was said.
    static func unusableReason(_ kind: HidingEngineKind, _ inputs: EngineChoiceInputs) -> String {
        if let reason = inputs.availability[kind]?.reason { return reason }
        if inputs.failedOut.contains(kind) { return "it failed 3 times in a row; Refresh Menu Bar tries it again" }
        return "it isn't set up"
    }
}

/// What Diagnostics says about hiding: the engine in use and why, how each engine stands, and the last error.
public struct EngineStatus: Sendable, Equatable, Codable {
    public let kind: HidingEngineKind
    /// Why this engine, with what it couldn't do, when it couldn't do something (the switches' apps that aren't in macOS's list).
    public let reason: String
    /// The engine only works approximately (the spacer).
    public let degraded: Bool
    /// Each engine's availability as a sentence: `available`, `needs permission: …` or `broken: …`. Words for Diagnostics to show as
    /// they are: nothing reads them apart (`unavailableReasons` is for that).
    public let availability: [HidingEngineKind: String]
    /// The bare reason (no "broken:", no full stop) of each engine that can't be used now. An engine that can be used has no entry, and
    /// neither has one that wasn't asked.
    public let unavailableReasons: [HidingEngineKind: String]
    /// What went wrong the last time a plan was applied, until one is applied well.
    public let lastError: String?
    /// The method the engine in use was last chosen for, once that choice was made to the end: its switch done and the engine before it
    /// taken down. While a switch is under way it is still the method before, so Settings can say that one is under way. Nil before the
    /// first choice, and for a status written before this was kept.
    public let decidedFor: HidingMethodChoice?

    public init(kind: HidingEngineKind, reason: String, degraded: Bool, availability: [HidingEngineKind: String], lastError: String?,
                unavailableReasons: [HidingEngineKind: String] = [:], decidedFor: HidingMethodChoice? = nil) {
        self.kind = kind
        self.reason = reason
        self.degraded = degraded
        self.availability = availability
        self.unavailableReasons = unavailableReasons
        self.lastError = lastError
        self.decidedFor = decidedFor
    }

    private enum CodingKeys: String, CodingKey {
        case kind, reason, degraded, availability, unavailableReasons, lastError, decidedFor
    }

    // A status written before the reasons (or the method) were kept has none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try container.decode(HidingEngineKind.self, forKey: .kind),
                  reason: try container.decode(String.self, forKey: .reason),
                  degraded: try container.decode(Bool.self, forKey: .degraded),
                  availability: try container.decode([HidingEngineKind: String].self, forKey: .availability),
                  lastError: try container.decodeIfPresent(String.self, forKey: .lastError),
                  unavailableReasons: try container.decodeIfPresent([HidingEngineKind: String].self, forKey: .unavailableReasons) ?? [:],
                  decidedFor: try container.decodeIfPresent(HidingMethodChoice.self, forKey: .decidedFor))
    }
}
