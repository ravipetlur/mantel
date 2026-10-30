import Foundation
import MKCore
import MKLayout

/// Whether Mantel can write macOS's order table now.
public enum LayoutWriterAvailability: Sendable, Equatable {
    case available
    /// The layout file hasn't been given to Mantel.
    case needsGrant
    /// A write has to wait, and the text says why.
    case held(String)
    /// Reordering is off on this Mac, and the text says so.
    case broken(String)
}

/// Why a write or a restore didn't happen.
public enum LayoutWriteError: Error, Equatable, LocalizedError {
    case needsGrant
    case broken(String)
    /// macOS put the order back, twice.
    case notAccepted
    /// The text says what happened, for the log and Diagnostics.
    case failed(String)

    /// What the person is told, as a toast or in Settings. (The detail of a `failed` write is for the log.)
    public var errorDescription: String? {
        switch self {
        case .needsGrant: LayoutWords.needsGrant
        case .broken(let text): text
        case .notAccepted: LayoutWords.notAccepted
        case .failed: LayoutWords.couldntChange
        }
    }
}

/// What one write of the order table did.
public struct LayoutWriteReport: Sendable, Equatable, Codable {
    public let at: Date
    /// How many distances were written, over both tries.
    public let written: Int
    /// How many times the table was written: 1, or 2 when the bar didn't show the first.
    public let attempts: Int
    /// `matches` (the bar shows the order, or nothing needed writing) or `cantTell` (too little is drawn to compare: cfprefsd holding the
    /// values is what counts).
    public let verdict: String
    /// The items no key was found for: their order can't be written.
    public let unresolved: [ItemID]
    /// The resolver's memory after this write; the session keeps it.
    public let memory: [ItemID: String]
    /// What wasn't written because the places of the apps around it can't be told: Mantel's own items (autosave names) and named apps
    /// (their identity).
    public let notPlaced: [String]
    /// The apps whose items' distances were written: what is learned of the order of their items is stale.
    public let appsWritten: [String]
    /// How many places the write worked out that move an icon on the bar (the keys it was to write, whether or not the table already had
    /// them, of Mantel's own items and of apps that are running: an app that isn't running has no icon to move): 0 when it placed nothing
    /// at all. Nil for a report that was saved before this was kept.
    public let placed: Int?

    public init(at: Date, written: Int, attempts: Int, verdict: String, unresolved: [ItemID], memory: [ItemID: String],
                notPlaced: [String] = [], appsWritten: [String] = [], placed: Int? = nil) {
        self.at = at
        self.written = written
        self.attempts = attempts
        self.verdict = verdict
        self.unresolved = unresolved
        self.memory = memory
        self.notPlaced = notPlaced
        self.appsWritten = appsWritten
        self.placed = placed
    }
}

/// What the layout writer is doing and has done: what Settings and Diagnostics show.
public struct LayoutStatus: Sendable, Equatable {
    public let availability: LayoutWriterAvailability
    public let lastReport: LayoutWriteReport?
    public let lastError: LayoutWriteError?
    /// When `lastError` happened: nil when there is no error, or when the writer didn't say.
    public let lastErrorAt: Date?
    /// From the request of a write until its verification ends (nothing follows the bar or the table meanwhile).
    public let isPending: Bool
    /// The bar is being re-sorted: from the write until its verification ends.
    public let isSettling: Bool
    /// Mantel's arrangement is in the table: "Restore original layout" has something to put back.
    public let hasKeptChanges: Bool
    /// Whether the dots can be kept beside the clock on this Mac (the switch isn't shown otherwise).
    public let dotsPlacementOffered: Bool

    public init(availability: LayoutWriterAvailability, lastReport: LayoutWriteReport?, lastError: LayoutWriteError?, isPending: Bool,
                isSettling: Bool, hasKeptChanges: Bool, dotsPlacementOffered: Bool, lastErrorAt: Date? = nil) {
        self.availability = availability
        self.lastReport = lastReport
        self.lastError = lastError
        self.lastErrorAt = lastErrorAt
        self.isPending = isPending
        self.isSettling = isSettling
        self.hasKeptChanges = hasKeptChanges
        self.dotsPlacementOffered = dotsPlacementOffered
    }
}

/// The words of the layout writer.
public enum LayoutWords {
    public static let broken = "macOS keeps the menu bar's order somewhere Mantel doesn't know on this version, so reordering is off. ⌘-drag icons instead."
    public static let needsGrant = "Grant access to the layout file in Settings › Layout first."
    public static let heldForAProbe = "A platform test is changing the menu bar. Mantel writes the order when it finishes."
    public static let heldForTheSpacer = "The wide spacer is hiding icons, so Mantel waits to change the order."
    /// The toast when macOS puts the order back twice.
    public static let notAccepted = "macOS didn't accept the new order"
    public static let couldntChange = "Couldn't change the menu bar order"
    /// What the bar shows while it is re-sorted: the reason a picture of it isn't taken.
    public static let resorting = "The menu bar is being re-sorted."
    static let notAcceptedLogLine = "macOS didn't accept the new order after two tries"
}

/// Whether a write of the table has to wait, and why: a platform test is changing the menu bar, or the wide spacer is hiding icons (its
/// own items aren't in the arrangement).
public enum LayoutHold {
    /// Every reason there is, as `reason(…)` says it: what a write that was held fails with.
    public static let reasons = [LayoutWords.heldForAProbe, LayoutWords.heldForTheSpacer]

    public static func reason(probeChangingMenuBar: Bool, engine: HidingEngineKind?) -> String? {
        if probeChangingMenuBar { return LayoutWords.heldForAProbe }
        if engine == .spacer { return LayoutWords.heldForTheSpacer }
        return nil
    }
}
