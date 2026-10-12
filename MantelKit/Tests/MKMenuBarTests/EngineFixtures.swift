import CoreGraphics
import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Synchronization

@testable import MKMenuBar

/// What the engine tests share. Every app is a synthetic `com.example.*` one.
enum EngineFixtures {
    static let own = "com.example.mantel"

    /// A plan: `visible` apps (Mantel's own is always among them) and `concealed` ones, and the system items that stay (all of them, less
    /// `concealedSystemItems`). It conceals the Hidden section as a whole unless `sections` says otherwise.
    static func plan(visible: Set<String> = [], concealed: Set<String> = [], concealedSystemItems: Set<Int> = [],
                     sections: Set<MenuBarSection>? = nil, source: PlanSource = .sections) -> VisibilityPlan {
        VisibilityPlan(visibleBundleIDs: visible.union([own]), concealedBundleIDs: concealed,
                       visibleSystemItems: Set(VisibilityPlan.allSystemItems).subtracting(concealedSystemItems),
                       concealedSections: sections ?? (concealed.isEmpty ? [] : [.hidden]), source: source)
    }

    /// A menu bar of this width, 31 points tall, on the display of that name.
    static func bar(_ width: CGFloat, display: String = "display") -> MenuBarGeometry {
        MenuBarGeometry(displayUUID: display, rect: CGRect(x: 0, y: 0, width: width, height: 31), notch: nil)
    }

    /// The desk's two bars: the portrait display's 1800 and the main display's 3360.
    static var deskBars: [MenuBarGeometry] {
        [bar(1800, display: "lg"), bar(3360, display: "main")]
    }
}

/// A list of what happened, in the order it did, for several fakes to write into.
final class CallLog: Sendable {
    private let lines = Mutex<[String]>([])

    var all: [String] { lines.withLock { $0 } }
    func add(_ line: String) { lines.withLock { $0.append(line) } }
    func count(_ line: String) -> Int { lines.withLock { $0.filter { $0 == line }.count } }
}

/// An engine that does what it is told and says what it did.
final class FakeEngine: HidingEngine {
    let kind: HidingEngineKind
    private let log: CallLog
    private struct State {
        var availability: EngineAvailability = .available
        /// How many applies throw, from now on; negative is always.
        var failures = 0
        /// The error an apply that fails throws is the one for preferences that haven't caught up.
        var unsettled = false
        var applied: [VisibilityPlan] = []
        var reapplied = 0
        var tornDown = 0
        var note: String?
    }
    private let state = Mutex(State())

    init(_ kind: HidingEngineKind, log: CallLog) {
        self.kind = kind
        self.log = log
    }

    private var name: String { kind.rawValue }

    var applied: [VisibilityPlan] { state.withLock { $0.applied } }
    var tornDown: Int { state.withLock { $0.tornDown } }
    /// How many of the applies were forced ones (`reapply`: they are in `applied` too).
    var reapplied: Int { state.withLock { $0.reapplied } }

    func setAvailability(_ availability: EngineAvailability) { state.withLock { $0.availability = availability } }
    /// The next `count` applies throw (always, when negative).
    func failNext(_ count: Int, unsettled: Bool = false) {
        state.withLock {
            $0.failures = count
            $0.unsettled = unsettled
        }
    }
    func setNote(_ note: String?) { state.withLock { $0.note = note } }

    func availability() async -> EngineAvailability {
        log.add("\(name).availability")
        return state.withLock { $0.availability }
    }

    func apply(_ plan: VisibilityPlan) async throws {
        log.add("\(name).apply")
        let failure = state.withLock { state -> HidingError? in
            state.applied.append(plan)
            guard state.failures != 0 else { return nil }
            if state.failures > 0 { state.failures -= 1 }
            return state.unsettled ? .notSettled(kind, "it was made to lag") : .failed(kind, "it was made to fail")
        }
        if let failure { throw failure }
    }

    func reapply(_ plan: VisibilityPlan) async throws {
        state.withLock { $0.reapplied += 1 }
        try await apply(plan)
    }

    func tearDown() async {
        log.add("\(name).tearDown")
        state.withLock { $0.tornDown += 1 }
    }

    func statusNote() async -> String? { state.withLock { $0.note } }
}

/// The app's spacer items, as far as the engine can tell: it notes every set of widths it was given.
@MainActor
final class FakeSpacers: SpacerControlling {
    private(set) var shown: [SpacerWidths] = []

    func show(widths: SpacerWidths) {
        shown.append(widths)
    }
}

/// A restarter that restarts nothing: it notes that it was asked, runs what a test gives it (the menu bar coming back, or taking its
/// time), and then succeeds or fails as told. Nothing here signals a process.
final class FakeRestarter: MenuBarAgentRestarting {
    private struct State {
        var failure: RestartError?
        var hook: (@Sendable () async -> Void)?
        var restarts = 0
    }

    private let log: CallLog
    private let state = Mutex(State())

    init(log: CallLog = CallLog()) {
        self.log = log
    }

    /// How many times it was asked to restart.
    var restarts: Int { state.withLock { $0.restarts } }

    /// The restart fails with this error (nil: it succeeds).
    func fail(with error: RestartError?) { state.withLock { $0.failure = error } }
    /// What happens while it restarts, before it succeeds or fails.
    func whileRestarting(_ body: (@Sendable () async -> Void)?) { state.withLock { $0.hook = body } }

    func restart() async throws(RestartError) {
        log.add("restart")
        let (failure, hook) = state.withLock { state -> (RestartError?, (@Sendable () async -> Void)?) in
            state.restarts += 1
            return (state.failure, state.hook)
        }
        await hook?()
        if let failure { throw failure }
    }
}
