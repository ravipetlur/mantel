import MKCore
import MKLayout

/// Which apps a read says whole: the ones whose icons it names for certain.
///
/// An icon's ID is its app's own name for it, or its place among the app's unnamed icons. A read that lacks an icon's name (the read of
/// it didn't come and nothing was remembered of it), that stops before the last item of the app's list (`AppExtras.listCut`), that has no
/// full answer from the app (`ReachStatus.isFullAnswer`), or that lists the app's items from two processes (an app started again while
/// the first still lists) can name an icon one way now and another way in the next read, or leave one out. Nothing is recorded of an
/// app from such a read.
///
/// A read in which MenuBarAgent's windows were read only in part (`Inventory.agentReadCut`) names every app's icons all the same, since
/// they come from the apps' own lists, and a slot that lacks its frame leaves no icon out. It does leave the icons of an app in another
/// order: the read lists an app's icons by where the bar has them, and an icon with no frame comes after those that have one. Which
/// records an app has is then the same, and the order of its records, which Stage B and the notes take from the read, may not be. So
/// such a read isn't whole for an app that has more than one icon of its own in it (a system icon is not an app's), that the read puts in
/// more than one of the groups the read orders them in: on the main bar, only on another bar, without a frame. An app that has one icon
/// is whole, as is one that is concealed (no icon of it has a frame, so they are all in one group and in order by ID) and one whose icons
/// all kept their frames (every one is on the main bar): a slot that lost its frame is the only way the cut can change an order.
///
/// An app that is read for the first time is believed when one process lists its items: there is no earlier read to differ from. (Two
/// processes at the first read are an app that was started again while the first still lists, and the read waits for the next.) After
/// that it takes two reads in a row that are made by the same processes.
struct WholeReads: Sendable, Equatable {
    /// The processes that listed each app's items in the read before, by bundle ID.
    private var processes: [String: Set<Int32>] = [:]

    /// The apps of `read` whose icons it names for certain. `running` is the apps that are running: what is remembered of one that isn't,
    /// and isn't in the read, is forgotten.
    mutating func wholeApps(in read: Inventory, running: Set<String>) -> Set<String> {
        var whole: Set<String> = []
        let mainBar = FollowTrust.mainBar(of: read)?.displayUUID
        for bundleID in read.appsWithItems {
            guard !read.unansweredApps.contains(bundleID), !read.incompleteApps.contains(bundleID),
                  read.reach.allSatisfy({ $0.bundleID != bundleID || $0.status.isFullAnswer }),
                  !(read.agentReadCut && Self.orderCanChange(ofApp: bundleID, in: read, mainBar: mainBar)),
                  let now = read.appProcesses[bundleID] else { continue }
            if let before = processes[bundleID] {
                if before == now { whole.insert(bundleID) }
            } else if now.count == 1 {
                whole.insert(bundleID)
            }
        }
        for (bundleID, now) in read.appProcesses { processes[bundleID] = now }
        processes = processes.filter { running.contains($0.key) || read.appProcesses[$0.key] != nil }
        return whole
    }

    /// Whether the app has more than one icon of its own that the read puts in more than one of the groups that `InventoryMatcher.ordered`
    /// lists them in.
    private static func orderCanChange(ofApp bundleID: String, in read: Inventory, mainBar: String?) -> Bool {
        let icons = read.items(ofApp: bundleID).filter { !$0.id.isSystem }
        guard icons.count > 1 else { return false }
        let groups = Set(icons.map { icon in
            if let mainBar, icon.frames[mainBar] != nil { 0 } else if icon.frames.isEmpty { 2 } else { 1 }
        })
        return groups.count > 1
    }
}
