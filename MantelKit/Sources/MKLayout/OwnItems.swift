import Foundation
import MKCore

// Mantel's own items in the layout: the spacers and the groups the person adds, with the words that tell them, and the dots and the
// divider, apart from the apps' icons.

/// The name of one spacer: 8 lowercase hexadecimal characters, made when the spacer is added and never changed. It is the last part of
/// the spacer's autosave name (`mantel.spacer.<id>`), so it can never be `divider` or `always`, the names the wide spacer's invisible
/// items go by.
///
/// It is written as a plain string, and a dictionary keyed by it as an object (`CodingKeyRepresentable`), as the repo's other keys are.
public struct SpacerID: RawRepresentable, Codable, Hashable, Sendable, CodingKeyRepresentable {
    public let rawValue: String

    /// Any string can be made into one, but an empty one, `always` and the names the wide spacer's invisible items go by are no own
    /// item's: the layout doesn't take one (`OwnItems.isOwn` says no).
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A new name, at random.
    public static func make() -> SpacerID {
        SpacerID(rawValue: OwnItems.makeIdentifier())
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The name of one group: made like a `SpacerID`, and the last part of the group's autosave name (`mantel.group.<id>`).
public struct GroupID: RawRepresentable, Codable, Hashable, Sendable, CodingKeyRepresentable {
    public let rawValue: String

    /// Any string can be made into one, but an empty one, `always` and the names the wide spacer's invisible items go by are no own
    /// item's: the layout doesn't take one (`OwnItems.isOwn` says no).
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A new name, at random.
    public static func make() -> GroupID {
        GroupID(rawValue: OwnItems.makeIdentifier())
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// What a spacer shows: a word, an emoji or an SF Symbol, by name.
///
/// It is written as `{"kind":"emoji","value":"…"}`.
public enum OwnItemLabel: Codable, Sendable, Equatable {
    case text(String)
    case emoji(String)
    case symbol(String)

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    private enum Kind: String {
        case text, emoji, symbol
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = try container.decodeIfPresent(String.self, forKey: .kind), let kind = Kind(rawValue: name),
              let value = try container.decodeIfPresent(String.self, forKey: .value) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath,
                                                                    debugDescription: "A label is a kind and a value."))
        }
        switch kind {
        case .text: self = .text(value)
        case .emoji: self = .emoji(value)
        case .symbol: self = .symbol(value)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(Kind.text.rawValue, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .emoji(let value):
            try container.encode(Kind.emoji.rawValue, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .symbol(let value):
            try container.encode(Kind.symbol.rawValue, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

/// What a group's icon looks like: an SF Symbol by name, an emoji, or a picture the person chose (a file name in the folder Mantel keeps
/// them in).
///
/// It is written as `{"kind":"symbol","value":"…"}`, or `{"kind":"image","fileName":"…"}`. A kind this version doesn't know is read as
/// `standard` (and said in the log).
public enum GroupLook: Codable, Sendable, Equatable {
    case symbol(String)
    case emoji(String)
    case image(fileName: String)

    /// The look of a group that was given none.
    public static let standard = GroupLook.symbol("square.grid.2x2")

    private enum CodingKeys: String, CodingKey {
        case kind, value, fileName
    }

    private enum Kind: String {
        case symbol, emoji, image
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = try container.decodeIfPresent(String.self, forKey: .kind) else {
            self = .standard
            return
        }
        switch Kind(rawValue: name) {
        case .symbol:
            self = try container.decodeIfPresent(String.self, forKey: .value).map(GroupLook.symbol) ?? .standard
        case .emoji:
            self = try container.decodeIfPresent(String.self, forKey: .value).map(GroupLook.emoji) ?? .standard
        case .image:
            self = try container.decodeIfPresent(String.self, forKey: .fileName).map { GroupLook.image(fileName: $0) } ?? .standard
        case nil:
            Log.warning("layout", "a group's look this version doesn't know was read as the standard one")
            self = .standard
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .symbol(let name):
            try container.encode(Kind.symbol.rawValue, forKey: .kind)
            try container.encode(name, forKey: .value)
        case .emoji(let text):
            try container.encode(Kind.emoji.rawValue, forKey: .kind)
            try container.encode(text, forKey: .value)
        case .image(let fileName):
            try container.encode(Kind.image.rawValue, forKey: .kind)
            try container.encode(fileName, forKey: .fileName)
        }
    }
}

/// A gap the person put in the menu bar, with a width and an optional label.
public struct LayoutSpacer: Codable, Sendable, Equatable, Identifiable {
    /// The width of a spacer that is just added, in points.
    public static let defaultWidth = 12
    /// The widths a spacer can have, in points.
    public static let widthRange = 4...200

    public let id: SpacerID
    /// 4 to 200 points. A width that is given outside them (a file's, the initializer's, or one set later and given to the layout:
    /// `SectionModel.addSpacer`, `updateSpacer`) is brought to the nearest of those.
    public var width: Int
    public var label: OwnItemLabel?

    public init(id: SpacerID = .make(), width: Int = LayoutSpacer.defaultWidth, label: OwnItemLabel? = nil) {
        self.id = id
        self.width = Self.clamped(width: width)
        self.label = label
    }

    /// The width within 4 to 200: the nearest end of the range for one outside it.
    static func clamped(width: Int) -> Int {
        min(max(width, widthRange.lowerBound), widthRange.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case id, width, label
    }

    // A key missing from the file takes its default. A label this version can't read is left out, and said in the log.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SpacerID.self, forKey: .id)
        width = Self.clamped(width: try container.decodeIfPresent(Int.self, forKey: .width) ?? Self.defaultWidth)
        do {
            label = try container.decodeIfPresent(OwnItemLabel.self, forKey: .label)
        } catch {
            Log.warning("layout", "a spacer's label this version doesn't know was left out")
            label = nil
        }
    }
}

/// An icon in the menu bar that opens a panel of other icons: the apps that were moved into it.
public struct IconGroup: Codable, Sendable, Equatable, Identifiable {
    public let id: GroupID
    public var title: String?
    /// What the group's icon looks like.
    public var look: GroupLook
    /// The panel opens when the pointer rests on the icon, and not only when it is clicked.
    public var opensOnHover: Bool
    /// The bundle IDs of the apps in the group, in order. The layout keeps them (`SectionModel.move(app:toGroup:at:)`).
    public var members: [String]

    public init(id: GroupID = .make(), title: String? = nil, look: GroupLook = .standard, opensOnHover: Bool = false,
                members: [String] = []) {
        self.id = id
        self.title = title
        self.look = look
        self.opensOnHover = opensOnHover
        self.members = members
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, look, opensOnHover, members
    }

    // A key missing from the file takes its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(GroupID.self, forKey: .id),
                  title: try container.decodeIfPresent(String.self, forKey: .title),
                  look: try container.decodeIfPresent(GroupLook.self, forKey: .look) ?? .standard,
                  opensOnHover: try container.decodeIfPresent(Bool.self, forKey: .opensOnHover) ?? false,
                  members: try container.decodeIfPresent([String].self, forKey: .members) ?? [])
    }
}

/// The names of Mantel's own items in the menu bar, and how an item is told to be one of them.
///
/// An item has two names that Mantel chooses: the autosave name the system keeps its place under (the layout table's key), and the
/// description it gives the accessibility tools (the menu bar's own tree gives status items no names, so the description is what finds
/// them). Both are here, and `kind(name:description:)` reads them back.
public enum OwnItems {
    /// The owner in the `ItemID` of every own item, whatever the app's bundle ID is (`mantel::mantel.spacer.<id>`), so that a layout
    /// travels to a build with another bundle ID.
    public static let owner = "mantel"

    /// What the system keeps each dot's place in the menu bar under.
    public static let hiddenDotName = "mantel.dot.hidden"
    public static let alwaysDotName = "mantel.dot.always"
    public static let dividerName = "mantel.divider.main"

    /// What each is called for the accessibility tools. A dot is found by it, so these never change: • is “Show hidden icons” and ••
    /// “Show all icons”.
    public static let hiddenDotDescription = "Show hidden icons"
    public static let alwaysDotDescription = "Show all icons"
    public static let dividerDescription = "Divider"
    public static let spacerDescription = "Spacer"

    /// What a group is called for the accessibility tools: its title and “group”, or “Icon group” for one with no title.
    public static func groupDescription(title: String?) -> String {
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? iconGroupDescription : "\(name) \(groupWord)"
    }

    private static let groupWord = "group"
    private static let iconGroupDescription = "Icon group"
    private static let spacerPrefix = "mantel.spacer."
    private static let groupPrefix = "mantel.group."

    // MARK: What an item is

    /// What an item of Mantel's is, by the name it keeps its place under or by what it is called for the accessibility tools. The name
    /// decides when it says; the description is read when the name says nothing of Mantel's own items.
    ///
    /// - **Names:** the dots', the divider's, `mantel.spacer.<id>` and `mantel.group.<id>`. A name in those two families whose id can't be
    ///   an own item's (it is empty, or it is one the wide spacer's invisible items go by: `divider`, `divider.2`, … and `always`) is
    ///   not an own item, and has no kind, whatever its description says.
    /// - **Descriptions:** the dots', the divider's, the spacer's, and any that ends “ group” (which is every group's, “Icon group”
    ///   among them).
    ///
    /// It doesn't say whose the item is: the caller asks it of the items of Mantel's own app.
    public static func kind(name: String?, description: String?) -> OwnItemKind? {
        if let name {
            switch verdict(ofName: name) {
            case .own(let kind): return kind
            case .notOwn: return nil
            case .noOpinion: break
            }
        }
        if let description, let described = kind(ofDescription: description) { return described }
        return nil
    }

    private enum NameVerdict {
        case own(OwnItemKind)
        /// The name is in one of Mantel's families, and isn't an own item's.
        case notOwn
        /// The name is none of Mantel's.
        case noOpinion
    }

    private static func verdict(ofName name: String) -> NameVerdict {
        switch name {
        case hiddenDotName: return .own(.hiddenDot)
        case alwaysDotName: return .own(.alwaysDot)
        case dividerName: return .own(.divider)
        default: break
        }
        if name.hasPrefix(spacerPrefix) {
            return isUsable(identifier: name.dropFirst(spacerPrefix.count)) ? .own(.spacer) : .notOwn
        }
        if name.hasPrefix(groupPrefix) {
            return isUsable(identifier: name.dropFirst(groupPrefix.count)) ? .own(.group) : .notOwn
        }
        return .noOpinion
    }

    private static func kind(ofDescription description: String) -> OwnItemKind? {
        switch description {
        case hiddenDotDescription: return .hiddenDot
        case alwaysDotDescription: return .alwaysDot
        case dividerDescription: return .divider
        case spacerDescription: return .spacer
        default: return description.hasSuffix(" \(groupWord)") ? .group : nil
        }
    }

    /// Whether an id can be an own spacer's or group's: it is not empty, and not one the wide spacer's invisible items go by
    /// (`divider`, `divider.2`, `divider.3`, … and `always`). The ids `make()` makes are always usable; one that is made by hand (a
    /// `SpacerID(rawValue:)` can hold anything) may not be, and is then no own item.
    static func isUsable(identifier: Substring) -> Bool {
        !identifier.isEmpty && identifier != "always" && identifier != "divider" && !identifier.hasPrefix("divider.")
    }

    /// Whether the layout can hold this spacer or group (`SectionModel.addSpacer`, `addGroup`): its id is usable.
    static func isUsable(_ spacer: SpacerID) -> Bool {
        isUsable(identifier: spacer.rawValue[...])
    }

    static func isUsable(_ group: GroupID) -> Bool {
        isUsable(identifier: group.rawValue[...])
    }

    // MARK: Identity

    /// A spacer's identity in the layout: `mantel::mantel.spacer.<id>`.
    public static func itemID(_ spacer: SpacerID) -> ItemID {
        ItemID(bundleID: owner, key: .identifier(spacerPrefix + spacer.rawValue))
    }

    /// A group's icon's identity in the layout: `mantel::mantel.group.<id>`.
    public static func itemID(_ group: GroupID) -> ItemID {
        ItemID(bundleID: owner, key: .identifier(groupPrefix + group.rawValue))
    }

    /// The name an own item keeps its place under: for the identity of an own item (the owner `mantel` and a name that is one of the
    /// kinds'), and nil for any other.
    public static func autosaveName(of item: ItemID) -> String? {
        guard item.bundleID == owner, case .identifier(let name) = item.key, kind(name: name, description: nil) != nil else { return nil }
        return name
    }

    /// Whether the identity is one of Mantel's own items'.
    public static func isOwn(_ item: ItemID) -> Bool {
        autosaveName(of: item) != nil
    }

    /// The spacer an identity names, or nil when it names anything else.
    public static func spacerID(of item: ItemID) -> SpacerID? {
        guard let name = autosaveName(of: item), kind(name: name, description: nil) == .spacer else { return nil }
        return SpacerID(rawValue: String(name.dropFirst(spacerPrefix.count)))
    }

    /// The group an identity names as its icon, or nil when it names anything else.
    public static func groupID(of item: ItemID) -> GroupID? {
        guard let name = autosaveName(of: item), kind(name: name, description: nil) == .group else { return nil }
        return GroupID(rawValue: String(name.dropFirst(groupPrefix.count)))
    }

    /// An item that a read gave, as the layout names it: `mantel::<autosave name>`. A read names an item of Mantel's by the running app's own
    /// bundle ID (`com.example.mantel::mantel.group.5e6f7a8b`), where the layout says `mantel` whatever the bundle ID is, so the two are
    /// never equal and this is what turns one into the other. Nil for an item that isn't one of Mantel's own, and for one that a read told
    /// only by its description (it has an index for a key, not its name): such a group icon is on the bar but has no group ID, so it is
    /// anchored against the right edge and has no hover.
    public static func layoutID(of item: MenuBarItem) -> ItemID? {
        guard item.isMantel, let kind = item.ownKind, case .identifier(let name) = item.id.key,
              Self.kind(name: name, description: nil) == kind else { return nil }
        return ItemID(bundleID: owner, key: .identifier(name))
    }

    /// 8 lowercase hexadecimal characters, from the system's random numbers.
    static func makeIdentifier() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(format: "%08x", UInt32.random(in: UInt32.min...UInt32.max, using: &generator))
    }
}
