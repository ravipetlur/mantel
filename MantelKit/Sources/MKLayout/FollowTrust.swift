import Foundation
import MKCore

/// Whether a read is whole enough for the order of the icons to be followed from it.
///
/// The order Mantel keeps follows the bar (`LayoutFollower`): the icons that a read has a place for are put in the order of their places,
/// and an icon the read has no place for keeps its place in the list. A read in which an app didn't answer has no frame for that app's
/// icons, and the icons that did answer are then put among the others' places in an order that isn't the bar's. On a busy Mac that is
/// what a read can be, and the list would be left unlike the bar. So a read is partial, and isn't followed, when:
/// - **an app that had an icon on the main bar in the last read that was trusted didn't answer** (`Inventory.unansweredApps`: it timed
///   out, or was left alone for timing out too often), **or answered in part** (`Inventory.incompleteApps`: an item's name didn't come, or
///   its list was cut): its icons are missing, or are named by their place and may not be the records the list holds, and that is told by
///   the app, not by counting;
/// - **MenuBarAgent's own read was cut** (`Inventory.agentReadCut`): a slot may lack its frame, or a window have been passed over;
/// - **slots that no answered app claims are more than the fewest seen** (a slot is drawn and no item claimed it: what a missing app that
///   wasn't known to have an icon leaves), unless the read before had that many too: an icon whose owner can't be told stays unclaimed for
///   ever, and two reads in a row that agree say that is the bar as it is now.
/// A read that is whole becomes what the next is judged by.
public struct FollowTrust: Sendable, Equatable {
    private var baseline: Int?
    private var previous: Int?
    private var appsOnTheBar: Set<String> = []

    public init() {}

    /// The slots of the main bar that no item claimed.
    public static func unclaimedSlots(in read: Inventory) -> Int {
        guard let bar = mainBar(of: read) else { return 0 }
        return read.untiedSlots[bar.displayUUID]?.count ?? 0
    }

    /// The main bar of a read: the one whose rect starts at the origin, or else the first.
    public static func mainBar(of read: Inventory) -> MenuBarGeometry? {
        read.bars.first(where: { $0.rect.origin == .zero }) ?? read.bars.first
    }

    /// The apps that draw an item on the main bar in this read.
    static func appsOnTheMainBar(in read: Inventory) -> Set<String> {
        guard let bar = mainBar(of: read) else { return [] }
        return Set(read.items.filter { $0.frames[bar.displayUUID] != nil && !$0.id.isSystem }.map(\.ownerBundleID))
    }

    /// Why a read isn't whole enough to follow the order from.
    public enum Doubt: Sendable, Equatable {
        /// Apps that had an icon on the main bar (sorted) didn't answer, or answered in part.
        case appsMissing([String])
        case agentReadCut
        /// Slots no answered app claims, more than the fewest seen (and than the read before had).
        case unclaimedSlots(Int)
    }

    /// Whether the order may be followed from this read. Asked once for each read that would be followed from.
    public mutating func trusts(_ read: Inventory) -> Bool {
        doubt(in: read) == nil
    }

    /// What makes this read unfit to follow the order from, or nil when it is whole. Asked once for each read that would be followed from.
    public mutating func doubt(in read: Inventory) -> Doubt? {
        guard !read.agentReadCut else { return .agentReadCut }
        let missing = appsOnTheBar.intersection(read.unansweredApps.union(read.incompleteApps))
        guard missing.isEmpty else {
            // What it counts includes the slots of the apps that are missing, so it says nothing to the next read.
            previous = nil
            return .appsMissing(missing.sorted())
        }
        let count = Self.unclaimedSlots(in: read)
        defer { previous = count }
        guard let fewest = baseline, count > fewest else {
            whole(count, read)
            return nil
        }
        guard previous == count else { return .unclaimedSlots(count) }
        whole(count, read)
        return nil
    }

    private mutating func whole(_ count: Int, _ read: Inventory) {
        baseline = count
        appsOnTheBar = Self.appsOnTheMainBar(in: read)
    }

    /// Forgets what was seen, for a read that is of another bar altogether (a reset).
    public mutating func forget() {
        baseline = nil
        previous = nil
        appsOnTheBar = []
    }
}
