import CoreGraphics
import MKCore

/// How wide each menu bar item is, as of the last time it was on the bar. A concealed item has no frame, so how much room
/// it would take when it came back is only known from then.
public struct ItemWidthCache: Sendable, Equatable {
    private var widths: [ItemID: CGFloat] = [:]
    /// What an item's app said its frame was, for an item that has never been seen with a slot's: better than not knowing, which would
    /// make an app that was moved for room one that is never tried again (a width that is unknown can't be said to fit).
    private var reported: [ItemID: CGFloat] = [:]

    public init() {}

    /// Records the width of every item that has a frame on a display, in the widest one if it has more than one. An item with no
    /// frame, or with a frame of no width, keeps the width it had; and an item an inventory doesn't hold (its app didn't answer,
    /// or has quit) isn't forgotten: the absence of an item never clears a width.
    public mutating func update(from inventory: Inventory) {
        for item in inventory.items {
            if let width = item.frames.values.map(\.width).max(), width > 0 {
                widths[item.id] = width
            } else if let width = item.reportedWidth, width > 0 {
                reported[item.id] = width
            }
        }
    }

    /// The last width the item had on the bar, else the width its app last said its frame was; nil if neither is known.
    public func width(of item: ItemID) -> CGFloat? {
        widths[item] ?? reported[item]
    }

    /// The width the item's slot had on a bar the last time it had one: nil when it never had (the width its app said its frame was is
    /// the icon's, and a slot is wider than the icon in it). What room an item takes on the bar is a slot's.
    public func slotWidth(of item: ItemID) -> CGFloat? {
        widths[item]
    }

    /// The width of everything an app has in the inventory, added up: the room all of it takes. Nil when the app has no item in the
    /// inventory or when any of its items has never been seen on the bar (an unknown width can't be added up).
    public func width(ofApp bundleID: String, in inventory: Inventory) -> CGFloat? {
        let items = inventory.items(ofApp: bundleID)
        guard !items.isEmpty else { return nil }
        var total: CGFloat = 0
        for item in items {
            guard let width = width(of: item.id) else { return nil }
            total += width
        }
        return total
    }
}
