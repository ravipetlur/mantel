import Foundation

/// Which of the apps offered for a relaunch the person has ticked. Nothing is ticked when the list opens, and only an app that was offered
/// can be ticked.
public struct RelaunchSelection: Sendable, Equatable {
    /// The apps offered, in the order of the list.
    private let candidates: [RelaunchCandidate]
    /// The bundle IDs of the apps that are ticked.
    public private(set) var ticked: Set<String>
    /// The apps that were relaunched: unticked, and not ticked again, as another press would only report them as relaunched without touching
    /// them. An app that didn't quit, or couldn't be opened, isn't here and can be tried again.
    public private(set) var relaunched: Set<String>

    /// A selection with nothing ticked.
    public init(candidates: [RelaunchCandidate]) {
        self.candidates = candidates
        ticked = []
        relaunched = []
    }

    /// Ticks the app, or un-ticks it when it is ticked. An ID that wasn't offered, or was relaunched, changes nothing.
    public mutating func toggle(_ id: String) {
        guard candidates.contains(where: { $0.id == id }), !relaunched.contains(id) else { return }
        if !ticked.insert(id).inserted { ticked.remove(id) }
    }

    /// Ticks every app offered, except those already relaunched.
    public mutating func selectAll() {
        ticked = Set(candidates.map(\.id)).subtracting(relaunched)
    }

    /// Takes in how a run came out: the apps relaunched are unticked and can't be ticked again, so Relaunch is available only for what is
    /// still ticked, which is the apps that didn't quit or couldn't be opened, and any not reached.
    public mutating func finish(_ outcomes: [String: RelaunchOutcome]) {
        for (id, outcome) in outcomes where outcome == .relaunched && candidates.contains(where: { $0.id == id }) {
            relaunched.insert(id)
            ticked.remove(id)
        }
    }

    /// Whether Relaunch can be pressed: something is ticked.
    public var canRelaunch: Bool { !ticked.isEmpty }

    /// The apps that are ticked, in the order of the list.
    public var chosen: [RelaunchCandidate] { candidates.filter { ticked.contains($0.id) } }
}

/// One press of Relaunch: the apps chosen, handed out one at a time, until all are done or a stop is asked for. A stop is only looked at
/// between apps, so that the app being relaunched is never left half way (nothing is cancelled).
public struct RelaunchRun: Sendable, Equatable {
    private var waiting: [RelaunchCandidate]
    /// Whether the person asked to stop: no app after the current one is started.
    public private(set) var stopRequested = false

    public init(chosen: [RelaunchCandidate]) {
        waiting = chosen
    }

    /// Asks the run to stop once the app being relaunched now has its outcome.
    public mutating func requestStop() {
        stopRequested = true
    }

    /// The next app to relaunch, or nil when all are done or a stop was asked for.
    public mutating func next() -> RelaunchCandidate? {
        guard !stopRequested, !waiting.isEmpty else { return nil }
        return waiting.removeFirst()
    }
}

extension RelaunchOutcome {
    /// What a row of the list says once its app has been dealt with.
    public var rowText: String {
        switch self {
        case .relaunched: "Relaunched"
        case .didNotQuit: "Didn't quit"
        case .couldNotOpen: "Couldn't open"
        }
    }
}
