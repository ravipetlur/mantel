import CoreGraphics
import Foundation

/// An item of an app, by the app's bundle ID and the item's place in its list.
public struct ExtraItemRef: Codable, Sendable, Hashable {
    public let bundleID: String?
    public let index: Int

    public init(bundleID: String?, index: Int) {
        self.bundleID = bundleID
        self.index = index
    }
}

/// Which items macOS has squeezed into its « overflow.
public enum OverflowAnalysis {
    /// Items in the overflow: an item with no frame, or whose frame is inside the chevron's (its center is in it), or a slot
    /// of an app that is that way when the app's own list of items doesn't account for it.
    ///
    /// A frame with no area counts as no frame. The chevron is the slot `MenuBarReader` marked.
    public static func overflowed(in snapshot: MenuBarSnapshot) -> [ExtraItemRef] {
        let chevron = snapshot.allSlots.first { $0.isOverflowChevron && ($0.frame.map { !$0.isEmpty } ?? false) }?.frame
        func isOverflowed(_ frame: CGRect?) -> Bool {
            guard let frame, !frame.isEmpty else { return true }
            guard let chevron else { return false }
            return chevron.contains(CGPoint(x: frame.midX, y: frame.midY))
        }

        var found: [ExtraItemRef] = []
        var bundlesFromTheirOwnLists: Set<String> = []
        for app in snapshot.apps {
            for item in app.items where isOverflowed(item.frame) {
                found.append(ExtraItemRef(bundleID: app.bundleID, index: item.index))
                if let bundleID = app.bundleID { bundlesFromTheirOwnLists.insert(bundleID) }
            }
        }

        // A slot MenuBarAgent has no frame for, whose app's own list says nothing of it: the app's next item, by order.
        var slotCounts: [pid_t: Int] = [:]
        for slot in snapshot.allSlots where !slot.isOverflowChevron {
            guard let owner = slot.ownerPID, let app = snapshot.apps.first(where: { $0.pid == owner }) else { continue }
            let ordinal = slotCounts[owner, default: 0]
            slotCounts[owner] = ordinal + 1
            guard isOverflowed(slot.frame) else { continue }
            if let bundleID = app.bundleID, bundlesFromTheirOwnLists.contains(bundleID) { continue }
            let reference = ExtraItemRef(bundleID: app.bundleID, index: ordinal)
            if !found.contains(reference) { found.append(reference) }
        }
        return found
    }
}
