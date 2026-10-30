import CoreGraphics
import Foundation
import MKCore

/// Whether an app's items are still in the slots a read tied them to: the second test a picture has to pass (the first is `BarSlotCheck`).
///
/// `BarSlotCheck` shows that the bar's slots, looked at after the strip, are the ones the read had. It can't show that the read tied each
/// item to the right one: an app's items are tied to a slot by the app's own frame, which is asked at another moment than the slots (a
/// bar that re-flows between the two ties items to their neighbours' slots, and the look agrees with the read), and two icons of one width
/// that trade places leave every slot where it was. So the apps whose items are cropped are asked for their frames once more, after the
/// strip, and an app's pictures are kept only when its frames are in the slots the read gave its items.
enum ItemFrameCheck {
    /// The apps (of `apps`) whose items, as the read tied them on the display's bar, are where the apps now say they are: each frame the app
    /// reports that lies in a slot of the bar lies in one of the slots the read gave the app's items, no two lie in one, and every slot the
    /// read gave them has one. The slot of a frame is the one the matcher gives it (`InventoryMatcher`): the closest of the slots that hold
    /// its center; a frame in none of them (an app that left one where macOS parks icons) says nothing.
    ///
    /// An app is compared as a set: its items are told apart by name or place, and two of its items that trade places are not seen. An app
    /// with no entry in `framesNow` (it didn't answer, or has no items now) is left out: nothing is known of where its items are.
    ///
    /// The system's items (`ItemID.systemBundleID`) are no app's: they are told by the slot's own name, which no frame can cross (no app's
    /// frame is the slot of a system module). They are kept when the read's slot of each of them carries its name, and then the look at the
    /// slots (`BarSlotCheck`) sees one that has traded places; a system item whose slot has no name was tied some other way, and isn't kept.
    ///
    /// **An app's frames are on one display's bar** (the read's `activeDisplay`, `framesDisplay`: the matcher ties the frames to the slots of
    /// that bar, and the other bars' slots are the same items by their names and order). For a capture of another bar the app's frames are
    /// compared with the slots the read gave its items on the bar they are on, and the bar that is captured is held to its own slots by the
    /// look at them (`BarSlotCheck`).
    static func appsStillTied(_ apps: Set<String>, read: Inventory, display: String, framesDisplay: String? = nil,
                              framesNow: [String: [CGRect]]) -> Set<String> {
        guard let slots = read.barSlots[display] else { return [] }
        return apps.filter { app in
            if app == ItemID.systemBundleID { return systemItemsAreNamed(in: read, display: display, slots: slots) }
            guard let now = framesNow[app] else { return false }
            let (given, onSlots) = givenFrames(of: app, read: read, display: display, framesDisplay: framesDisplay)
            return isTied(given: given, slots: onSlots, framesNow: now)
        }
    }

    /// The frames the read gave an app's items, and the slots of the bar they are on: those of the bar the app's frames are on when that is
    /// another than the one captured and the app has items there, else those of the bar captured.
    private static func givenFrames(of app: String, read: Inventory, display: String, framesDisplay: String?) -> (frames: [CGRect], slots: [BarSlot]) {
        if let framesDisplay, framesDisplay != display, let slots = read.barSlots[framesDisplay] {
            let frames = read.items(ofApp: app).compactMap { $0.frames[framesDisplay] }
            if !frames.isEmpty { return (frames, slots) }
        }
        return (read.items(ofApp: app).compactMap { $0.frames[display] }, read.barSlots[display] ?? [])
    }

    /// For the log, what is wrong with an app that isn't tied: how far its frames lie from the slots the read gave its items, or that it
    /// reports no icon, or another number of them.
    static func describeUntied(_ app: String, read: Inventory, display: String, framesDisplay: String? = nil, framesNow: [CGRect]) -> String {
        let given = givenFrames(of: app, read: read, display: display, framesDisplay: framesDisplay).frames.sorted { $0.minX < $1.minX }
        let now = framesNow.filter { !$0.isEmpty }.sorted { $0.minX < $1.minX }
        if now.isEmpty { return "\(app) reports no icon now" }
        guard now.count == given.count else { return "\(app) reports \(now.count) icons where the read had \(given.count)" }
        // The app's frame is inside its slot: the middles are compared.
        let shifts = zip(given, now).map { Int(($1.midX - $0.midX).rounded()) }
        guard let widest = shifts.max(by: { abs($0) < abs($1) }), widest != 0 else { return "\(app)'s frames are in other slots than the read's" }
        return "\(app)'s icons moved \(abs(widest)) pt \(widest < 0 ? "left" : "right")"
    }

    private static func systemItemsAreNamed(in read: Inventory, display: String, slots: [BarSlot]) -> Bool {
        // A module macOS has parked off the bar (AirDrop, under any allowlist) keeps a frame that is no slot of it: it is never cropped,
        // and says nothing of the others.
        let items = read.items(ofApp: ItemID.systemBundleID).filter { item in
            item.frames[display].map { frame in slots.contains { same($0.frame, frame) } } ?? false
        }
        guard !items.isEmpty else { return false }
        return items.allSatisfy { item in
            guard case .system(let module) = item.id.key, let frame = item.frames[display],
                  let slot = slots.first(where: { same($0.frame, frame) }) else { return false }
            return slot.name.flatMap(ItemID.systemModule(ofIdentifier:)) == module
        }
    }

    /// `given`: the slots the read gave an app's items on the bar; `slots`: every slot of the bar in the read, left to right;
    /// `framesNow`: the frames the app reports now.
    static func isTied(given: [CGRect], slots: [BarSlot], framesNow: [CGRect]) -> Bool {
        var wanted: Set<Int> = []
        for frame in given {
            guard let index = slots.firstIndex(where: { same($0.frame, frame) }) else { return false }
            wanted.insert(index)
        }
        guard !wanted.isEmpty else { return false }

        var found: Set<Int> = []
        for frame in framesNow where !frame.isEmpty {
            guard let index = slot(holding: frame, in: slots) else { continue }
            guard wanted.contains(index), found.insert(index).inserted else { return false }
        }
        return found == wanted
    }

    /// The closest of the slots that hold the frame, as the matcher says (`InventoryMatcher.slotsHolding`): the left one when two are as
    /// close, and never the slot of a system module (no app's frame is its).
    private static func slot(holding frame: CGRect, in slots: [BarSlot]) -> Int? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        var best: (index: Int, distance: CGFloat)?
        for (index, barSlot) in slots.enumerated() {
            let slot = barSlot.frame
            guard !slot.isEmpty, barSlot.name.map({ ItemID.systemModule(ofIdentifier: $0) == nil }) ?? true,
                  slot.insetBy(dx: -InventoryMatcher.slotOutset, dy: -InventoryMatcher.slotOutset).contains(center),
                  frame.width <= slot.width + InventoryMatcher.frameWidthTolerance else { continue }
            let distance = abs(slot.midX - center.x)
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        return best?.index
    }

    private static func same(_ one: CGRect, _ other: CGRect) -> Bool {
        let tolerance = BarSlotCheck.tolerance
        return abs(one.minX - other.minX) <= tolerance && abs(one.minY - other.minY) <= tolerance
            && abs(one.width - other.width) <= tolerance && abs(one.height - other.height) <= tolerance
    }
}
