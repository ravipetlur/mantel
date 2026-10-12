import Foundation
import MKLayout
import Synchronization

/// The three ways Mantel can take icons off the menu bar.
public enum HidingEngineKind: String, Codable, Sendable, CaseIterable {
    /// macOS's own allowlist of apps and system items, which conceals every status item that isn't on it.
    case allowlist
    /// The "Allow in the Menu Bar" switches in System Settings, changed one app at a time.
    case approvals
    /// A wide invisible item that pushes the icons beside it off the bar.
    case spacer

    /// The name Settings and Diagnostics give it.
    public var title: String {
        switch self {
        case .allowlist: "Allowlist"
        case .approvals: "System Settings switches"
        case .spacer: "Wide spacer"
        }
    }
}

/// A dictionary keyed by `HidingEngineKind` is written as a JSON object, as `MenuBarSection`'s is.
extension HidingEngineKind: CodingKeyRepresentable {}

/// Whether an engine can be used now, and if not, why (in words for the person).
public enum EngineAvailability: Sendable, Equatable {
    case available
    /// Mantel needs something the person has to give (a file chosen in Settings, a permission).
    case needsPermission(String)
    /// Something on this Mac keeps it from working.
    case broken(String)

    /// Whether it can be used.
    public var isAvailable: Bool {
        if case .available = self { true } else { false }
    }

    /// Why it can't, or nil when it can.
    public var reason: String? {
        switch self {
        case .available: nil
        case .needsPermission(let reason), .broken(let reason): reason
        }
    }

    /// As Diagnostics says it: `available`, `needs permission: …` or `broken: …`.
    public var statusText: String {
        switch self {
        case .available: "available"
        case .needsPermission(let reason): "needs permission: \(reason)"
        case .broken(let reason): "broken: \(reason)"
        }
    }
}

/// Why an engine wouldn't hide icons.
public enum HidingError: Error, Equatable, LocalizedError {
    /// It can't be used at all now (see `EngineAvailability`).
    case unavailable(HidingEngineKind, String)
    /// It was used, and macOS or the files it works on wouldn't have it.
    case failed(HidingEngineKind, String)
    /// It was used, and what macOS's preferences service holds hadn't caught up with the file it keeps, even after a second try. That
    /// is a matter of time, not of the engine: it shows everything like `failed`, but doesn't count toward failing the engine out. The
    /// reason is for the person, so it says nothing of which setting it was about.
    case notSettled(HidingEngineKind, String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let kind, let reason): "\(kind.title) can't be used: \(Self.sentence(reason))."
        case .failed(let kind, let reason), .notSettled(let kind, let reason): "\(kind.title) couldn't hide icons: \(Self.sentence(reason))."
        }
    }

    /// The reason without the full stop it may end in, so that the one that closes the message isn't doubled.
    private static func sentence(_ reason: String) -> String {
        var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// A way of taking icons off the menu bar. One is in use at a time (`HidingController`); every engine hides what the plan conceals and
/// leaves the rest as it is.
public protocol HidingEngine: Sendable {
    var kind: HidingEngineKind { get }
    /// Whether it can be used now. Cheap enough to ask whenever the choice of engine is made again.
    func availability() async -> EngineAvailability
    /// Makes the menu bar what the plan says, replacing the plan before it. Calling it again with the same plan changes nothing.
    /// - Throws: `HidingError`. An engine that throws has shown everything: it leaves nothing hidden that the plan didn't ask for. (The
    ///   controller tears it down to make sure.)
    func apply(_ plan: VisibilityPlan) async throws
    /// Applies the plan as `apply` does, without taking it that what was applied before is still in force: Refresh asks for it, to start
    /// over from what is true. An engine that remembers what it applied, and so applies an equal plan as nothing, makes the plan live
    /// again; one that reads what is there each time (the switches) has nothing more to do, and that is what the default does.
    func reapply(_ plan: VisibilityPlan) async throws
    /// Shows everything and undoes whatever this engine changed. Safe to call when it changed nothing.
    func tearDown() async
    /// A sentence about what the engine could not do with the last plan, for Diagnostics (nil when there is nothing to say).
    func statusNote() async -> String?
}

extension HidingEngine {
    public func reapply(_ plan: VisibilityPlan) async throws {
        try await apply(plan)
    }

    public func statusNote() async -> String? {
        nil
    }
}

/// Lets one task at a time through a stretch of an actor's code that awaits, so that a second call to the actor can't start in the
/// middle of the first (an actor serves other calls while one is suspended). Calls are let through in the order they came.
///
/// A task that is waiting here isn't woken by being cancelled: the one that is through always leaves, and the next goes.
final class Turnstile: Sendable {
    private struct State {
        var busy = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func enter() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let mustWait = state.withLock { state -> Bool in
                if state.busy {
                    state.waiting.append(continuation)
                    return true
                }
                state.busy = true
                return false
            }
            if !mustWait { continuation.resume() }
        }
    }

    func leave() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiting.isEmpty else {
                state.busy = false
                return nil
            }
            return state.waiting.removeFirst()
        }
        next?.resume()
    }
}
