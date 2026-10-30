import CoreGraphics

/// What a distance in macOS's order table is measured from.
public enum DistanceReference: String, Codable, Sendable {
    /// From the bar's right edge to the item's right edge.
    case rightEdge
    /// From the bar's right edge to the item's left edge.
    case leftEdge
    /// From no fixed edge: the distances only say which item is left of which.
    case orderOnly
}

/// How an item that names itself to nothing (`ItemID.index`) is matched to a key of the table.
public enum KeyMatchRule: Sendable, Equatable {
    /// The app's n-th item is the key named `<prefix><n>`.
    case autosaveIndex(prefix: String)
    /// The app's keys are matched to its drawn slots by distance, nearest first, within the tolerance.
    case byDistance(tolerance: CGFloat)
    /// Only an item with a name of its own has a key.
    case identifiersOnly
    /// An app's nameless items are matched to its keys that no named item holds, by count and rank: when the app has exactly as many such
    /// keys as nameless items, one item gets its one key, and several are matched left to right on the bar against the keys from the
    /// largest distance down (a larger distance is further left; distances only order). Several items are matched only when every one is
    /// drawn on one bar, in a slot of its own, and the app is neither concealed by the plan nor contested, and no two of the keys share a
    /// distance. A match is kept only if each matched item is on the bar on the same side of every drawn token with a key of its own as
    /// its key is in the table. Anything else leaves the app's nameless items without a key. Nothing is remembered between resolutions.
    case byRank
}

/// Whether an app's own frames for its items move as soon as macOS re-sorts the bar.
public enum FramesAfterResort: String, Sendable {
    /// They move with the re-sort.
    case follow
    /// They stay where they were for a while; only the slots (and what names them) are current.
    case lag
}

/// What was found out about how macOS keeps the menu bar's order, in one value. The coordinator builds it once and gives it to the
/// applier and the session.
public struct LayoutRules: Sendable, Equatable {
    public var reference: DistanceReference
    public var keyMatch: KeyMatchRule
    /// A distance is a sum of the widths to its right, so an item of unknown width can't be placed (it is skipped).
    public var needsKnownWidths: Bool
    /// Why reordering is off on this Mac, in words for the person; nil when it works.
    public var broken: String?
    /// How long a write is given to show on the bar.
    public var verificationWait: Duration
    public var frames: FramesAfterResort
    /// Whether the dots can be kept beside the clock.
    public var dotsPlacementOffered: Bool

    public init(reference: DistanceReference, keyMatch: KeyMatchRule, needsKnownWidths: Bool, broken: String?,
                verificationWait: Duration, frames: FramesAfterResort, dotsPlacementOffered: Bool) {
        self.reference = reference
        self.keyMatch = keyMatch
        self.needsKnownWidths = needsKnownWidths
        self.broken = broken
        self.verificationWait = verificationWait
        self.frames = frames
        self.dotsPlacementOffered = dotsPlacementOffered
    }

    /// What is assumed before anything is measured: the weakest of each.
    public static let unmeasured = LayoutRules(reference: .orderOnly, keyMatch: .identifiersOnly, needsKnownWidths: true, broken: nil,
                                               verificationWait: .seconds(3), frames: .lag, dotsPlacementOffered: false)

    /// What was measured of this Mac: distances only order, a write re-sorts the bar and the apps' frames follow it. That nameless items
    /// have no key of their own was measured too; matching them to the keys of their app by count and rank is a later choice, not a
    /// measurement.
    public static let measured = LayoutRules(reference: .orderOnly, keyMatch: .byRank, needsKnownWidths: false, broken: nil,
                                             verificationWait: .milliseconds(5350), frames: .follow, dotsPlacementOffered: false)
}
