import CoreGraphics
import Foundation
import MKCore

/// What asked for a reveal, as far as it matters for how the reveal is shown (`RevealPresentationPolicy`): the trigger, and for a click on
/// a dot, which dot.
public struct RevealCause: Sendable, Equatable {
    public let trigger: RevealTrigger
    /// The dot that was clicked, for `.dot`.
    public let dot: DotKind?

    public init(trigger: RevealTrigger, dot: DotKind? = nil) {
        self.trigger = trigger
        self.dot = dot
    }

    /// What an event says about why a reveal is asked for: nil for an event that can't begin one. (The hotkey for the second bar is
    /// told apart by whoever sends it: it is a `.show` that opens the bar whatever the setting is.)
    public static func of(_ event: RevealEvent) -> RevealCause? {
        switch event {
        case .dotClicked(let dot): RevealCause(trigger: .dot, dot: dot)
        case .pointerEnteredEmptySpace: RevealCause(trigger: .hover)
        case .emptySpaceClicked: RevealCause(trigger: .emptySpaceClick)
        case .scrolled: RevealCause(trigger: .scroll)
        case .toggle: RevealCause(trigger: .hotkey)
        case .show: RevealCause(trigger: .command)
        case .pointerLeftEmptySpace, .setFocusMode, .toggleFocusMode, .guardsChanged, .revealConfirmed, .timerFired, .settingsChanged:
            nil
        }
    }
}

/// What a panel is anchored to, kept for as long as it is open so that it can be put under the item again whenever the bar is read anew.
public enum PanelAnchorSpec: Sendable, Equatable {
    /// The second bar: the kind of anchor, the dot that was clicked and the pointer's place (CoreGraphics global points) then.
    case secondBar(SecondBarAnchorKind, dot: DotKind?, pointer: CGPoint)
    /// A group's panel, under its icon.
    case group(GroupID)
}

/// Where a panel of Mantel's is put, from what the last read of the menu bar says of the item it opens from.
///
/// A panel never goes by the frame of a status item's own button: that matches the slot macOS draws only on the display that is active,
/// and is somewhere else on the others. It goes by the slot the last read found the item in, found by what the item is (`ownKind`).
///
/// A read can't be trusted for a slot when it is older than the last change of displays (the frames are still in the old coordinates),
/// and a dot whose frame another dot's shares on that display has no slot of its own (which of the two is where can't be told).
public enum PanelAnchors {
    /// The slot an item of Mantel's of this kind has on a display's bar, in CoreGraphics global points. Nil when the last read has none for
    /// it there: the item isn't on the bar (the dots hidden, •• with nothing in Always Hidden), or is out of the way (behind the notch, in
    /// the « menu), or the read can't be trusted for it.
    ///
    /// - Parameter displaysChangedAt: when the displays last changed; a read taken before it has no slot.
    public static func slotFrame(of kind: OwnItemKind, on display: String, in inventory: Inventory, displaysChangedAt: Date? = nil) -> CGRect? {
        slotFrame(on: display, in: inventory, displaysChangedAt: displaysChangedAt) { $0.ownKind == kind }
    }

    /// The slot of one group's icon on a display's bar.
    public static func slotFrame(ofGroup group: GroupID, on display: String, in inventory: Inventory, displaysChangedAt: Date? = nil) -> CGRect? {
        let icon = OwnItems.itemID(group)
        // A read gives the icon the app's own bundle ID, not the layout's `mantel`: it is found by what `layoutID` makes of it.
        return slotFrame(on: display, in: inventory, displaysChangedAt: displaysChangedAt) { OwnItems.layoutID(of: $0) == icon }
    }

    private static func slotFrame(on display: String, in inventory: Inventory, displaysChangedAt: Date?,
                                  where matches: (MenuBarItem) -> Bool) -> CGRect? {
        if let displaysChangedAt, inventory.capturedAt < displaysChangedAt { return nil }
        for item in inventory.items where matches(item) && !item.overflowedOn.contains(display) && !item.sharesFrameOn.contains(display) {
            if let frame = item.frames[display], frame.width > 0 { return frame }
        }
        return nil
    }

    /// Where the second bar goes for a reveal: under the slot of the dot that was clicked (the setting says so), at the pointer, or
    /// against the right edge. Whatever can't be found (the dots hidden, or the dot out of the way) is against the right edge, on the
    /// display the pointer is on.
    public static func secondBar(_ kind: SecondBarAnchorKind, dot: DotKind?, display: String, inventory: Inventory,
                                 pointer: CGPoint, displaysChangedAt: Date? = nil) -> SecondBarAnchor {
        switch kind {
        case .pointer:
            return .pointer(pointer)
        case .rightAligned:
            return .rightAligned
        case .underDot:
            let owned: OwnItemKind = dot == .always ? .alwaysDot : .hiddenDot
            return slotFrame(of: owned, on: display, in: inventory, displaysChangedAt: displaysChangedAt).map(SecondBarAnchor.under) ?? .rightAligned
        }
    }

    /// Where a group's panel goes: under its icon's slot, or against the right edge when the icon isn't found.
    public static func group(_ group: GroupID, display: String, inventory: Inventory, displaysChangedAt: Date? = nil) -> SecondBarAnchor {
        slotFrame(ofGroup: group, on: display, in: inventory, displaysChangedAt: displaysChangedAt).map(SecondBarAnchor.under) ?? .rightAligned
    }

    /// Where a panel that was opened from `anchor` goes now, by the newest read: the item is found again every time, so a panel follows
    /// the item when the bar moves it.
    public static func resolve(_ anchor: PanelAnchorSpec, display: String, inventory: Inventory, displaysChangedAt: Date? = nil) -> SecondBarAnchor {
        switch anchor {
        case .secondBar(let kind, let dot, let pointer):
            secondBar(kind, dot: dot, display: display, inventory: inventory, pointer: pointer, displaysChangedAt: displaysChangedAt)
        case .group(let id):
            group(id, display: display, inventory: inventory, displaysChangedAt: displaysChangedAt)
        }
    }

    /// The frames of every item of Mantel's on the bars, for telling a click on one of them from a click outside a panel.
    public static func ownItemFrames(in inventory: Inventory) -> [CGRect] {
        inventory.items.filter { $0.ownKind != nil }.flatMap { $0.frames.values }
    }
}
