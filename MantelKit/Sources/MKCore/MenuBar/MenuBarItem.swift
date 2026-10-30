import CoreGraphics

/// One item in the menu bar, whichever app or part of macOS draws it.
public struct MenuBarItem: Codable, Sendable, Equatable, Identifiable {
    public let id: ItemID
    /// The app that draws it; `ItemID.systemBundleID` for a system item.
    public let ownerBundleID: String
    public let appName: String?
    /// The item's Accessibility title or description. It can hold a network's name or a battery level, so it is for showing in
    /// Settings only, and is never logged or copied.
    public let label: String?
    /// Where the item is on each display (`DisplayInfo.uuid` to a CoreGraphics global frame). Empty while the item is
    /// concealed: the frame its app reports for it then is stale, and isn't kept.
    public let frames: [String: CGRect]
    /// The displays where the item is in the « overflow or behind the notch.
    public let overflowedOn: Set<String>
    public let isMantel: Bool
    /// The item is one of Mantel's two dots (• and ••), and not one of its other items (the wide spacer's invisible ones). Only the dots
    /// are made room for, and only they say whether a dot is in the « menu. Whenever `ownKind` says what the item is, this follows it: a
    /// dot for the two dots, and never for a spacer, the divider or a group's icon. With no kind it is as it was given.
    public let isDot: Bool
    /// What the item is when it is one of Mantel's own (a dot, the divider, a spacer, a group's icon); nil for every other item, and for
    /// the invisible items of Mantel's that the wide spacer uses.
    public let ownKind: OwnItemKind?
    /// Where the item says it is on a display's bar when none of that bar's slots is there: wholly on the bar, and in no slot. MenuBarAgent
    /// draws an item in a slot, so an item that says it is somewhere else on the bar is not drawn where it says. An item that macOS has put
    /// out of the way (behind the notch, under the app's menus, in the « menu) reports the place it would have, which is such a place.
    /// (`BarRegion` tells which of them are out of the way.) An item that is concealed is off every bar, and is none of these.
    public let strayFrames: [String: CGRect]
    /// The displays in `overflowedOn` that were found out by where the item says it is (`BarRegion`), and not by the bar's slots.
    public let inferredOverflowOn: Set<String>
    /// For a dot: the displays whose bar holds a frame that this dot and another report as one and the same. A frame is one icon's, so
    /// two that give one is a frame left over from the middle of a change (a display change moves them), and where the dots are can't be
    /// told from the frames of either.
    public let sharesFrameOn: Set<String>
    /// The width of the frame the item's app reports for it, whether or not a slot is its: what the item takes when nothing better is known
    /// (the slot's width is what it takes on the bar, and an icon's own frame is a little narrower than that, or a little wider).
    public let reportedWidth: CGFloat?

    public init(id: ItemID, ownerBundleID: String, appName: String?, label: String?, frames: [String: CGRect],
                overflowedOn: Set<String>, isMantel: Bool, isDot: Bool = false, strayFrames: [String: CGRect] = [:],
                inferredOverflowOn: Set<String> = [], sharesFrameOn: Set<String> = [], reportedWidth: CGFloat? = nil,
                ownKind: OwnItemKind? = nil) {
        self.id = id
        self.ownerBundleID = ownerBundleID
        self.appName = appName
        self.label = label
        self.frames = frames
        self.overflowedOn = overflowedOn
        self.isMantel = isMantel
        self.isDot = ownKind.map(\.isDot) ?? isDot
        self.ownKind = ownKind
        self.strayFrames = strayFrames
        self.inferredOverflowOn = inferredOverflowOn
        self.sharesFrameOn = sharesFrameOn
        self.reportedWidth = reportedWidth
    }

    private enum CodingKeys: String, CodingKey {
        case id, ownerBundleID, appName, label, frames, overflowedOn, isMantel, isDot, ownKind, strayFrames, inferredOverflowOn, sharesFrameOn, reportedWidth
    }

    /// An item saved before the last six were kept has none of them.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ItemID.self, forKey: .id)
        ownerBundleID = try container.decode(String.self, forKey: .ownerBundleID)
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        frames = try container.decode([String: CGRect].self, forKey: .frames)
        overflowedOn = try container.decode(Set<String>.self, forKey: .overflowedOn)
        isMantel = try container.decode(Bool.self, forKey: .isMantel)
        // A kind this version doesn't know is read as none, and said in the log, so one item can't fail the whole inventory.
        let ownKind = container.decodeLeniently(OwnItemKind.self, forKey: .ownKind, category: "inventory")
        self.ownKind = ownKind
        let savedIsDot = try container.decodeIfPresent(Bool.self, forKey: .isDot) ?? false
        isDot = ownKind.map(\.isDot) ?? savedIsDot
        strayFrames = try container.decodeIfPresent([String: CGRect].self, forKey: .strayFrames) ?? [:]
        inferredOverflowOn = try container.decodeIfPresent(Set<String>.self, forKey: .inferredOverflowOn) ?? []
        sharesFrameOn = try container.decodeIfPresent(Set<String>.self, forKey: .sharesFrameOn) ?? []
        reportedWidth = try container.decodeIfPresent(CGFloat.self, forKey: .reportedWidth)
    }

    /// What is saved is the same on every run: the sets of displays are written as lists in order (a set has no order of its own, and
    /// would be written in a different one by every process).
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(ownerBundleID, forKey: .ownerBundleID)
        try container.encodeIfPresent(appName, forKey: .appName)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encode(frames, forKey: .frames)
        try container.encode(overflowedOn.sorted(), forKey: .overflowedOn)
        try container.encode(isMantel, forKey: .isMantel)
        try container.encode(isDot, forKey: .isDot)
        try container.encodeIfPresent(ownKind, forKey: .ownKind)
        try container.encode(strayFrames, forKey: .strayFrames)
        try container.encode(inferredOverflowOn.sorted(), forKey: .inferredOverflowOn)
        try container.encode(sharesFrameOn.sorted(), forKey: .sharesFrameOn)
        try container.encodeIfPresent(reportedWidth, forKey: .reportedWidth)
    }

    /// The item has no place on any bar: macOS isn't drawing it.
    public var isConcealed: Bool { frames.isEmpty }

    /// The item is in the « overflow or behind the notch on at least one display.
    public var isOverflowed: Bool { !overflowedOn.isEmpty }

    /// The item, found to be out of the way on these displays by where it says it is (`inferredOverflowOn`).
    public func overflowedByPlace(on displays: Set<String>) -> MenuBarItem {
        MenuBarItem(id: id, ownerBundleID: ownerBundleID, appName: appName, label: label, frames: frames,
                    overflowedOn: overflowedOn.union(displays), isMantel: isMantel, isDot: isDot, strayFrames: strayFrames,
                    inferredOverflowOn: inferredOverflowOn.union(displays.subtracting(overflowedOn)), sharesFrameOn: sharesFrameOn,
                    reportedWidth: reportedWidth, ownKind: ownKind)
    }
}
