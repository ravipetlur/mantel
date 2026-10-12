import CoreGraphics
import Foundation

/// Which of a display's slots macOS has put in its « overflow, or behind the camera housing.
///
/// When a bar runs out of room, macOS doesn't take the slots away: they stay in the list, piled up at the « with stale frames, or
/// with no frame at all.
enum OverflowDetector {
    /// The role of the « slot: the only one on a bar that is a button. Its text is localized, so it is never matched.
    static let chevronRole = "AXButton"

    static func isChevron(_ slot: AgentSlot) -> Bool {
        slot.role == chevronRole
    }

    /// Where the « is among `slots`: the first one that is a button.
    static func chevronPosition(in slots: [AgentSlot]) -> Int? {
        slots.firstIndex(where: isChevron)
    }

    /// The positions in `slots` of the items that are overflowed. The « is not an item and is never in the answer.
    ///
    /// An item is overflowed when
    /// - its midpoint is left of the « (every slot of a pile shares about one x, and they all are left of it), or
    /// - it has no frame, or a frame with no width, or
    /// - on a notched display, its frame overlaps the notch.
    ///
    /// With no « on the bar, the first rule has nothing to compare with, so only the other two apply.
    ///
    /// - Parameters:
    ///   - chevron: the « slot's frame (nil when the bar has none, or it has no frame), in the same space as the slots.
    ///   - notch: the notch (nil on a display without one), in the same space as the slots.
    static func overflowed(slots: [AgentSlot], chevron: CGRect?, notch: CGRect?) -> Set<Int> {
        var found: Set<Int> = []
        for (position, slot) in slots.enumerated() where !isChevron(slot) {
            guard let frame = slot.frame, frame.width > 0 else {
                found.insert(position)
                continue
            }
            if let chevron, frame.midX < chevron.midX {
                found.insert(position)
            } else if let notch, overlaps(frame, notch) {
                found.insert(position)
            }
        }
        return found
    }

    /// Whether the two rectangles share some area. Rectangles that only touch along an edge don't.
    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let shared = a.intersection(b)
        return !shared.isNull && shared.width > 0 && shared.height > 0
    }
}
