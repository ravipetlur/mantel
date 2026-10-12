import Foundation

/// Who a menu bar item is, in a form that stays the same across launches and on another Mac. Nothing about it depends on a
/// process ID, a window or the order macOS happens to list things in.
///
/// - **`.identifier`**: the item's own name for itself (its autosave name or Accessibility identifier), together with the app that
///   draws it.
/// - **`.index`**: for an item that has no usable name, its position among that app's items from left to right.
/// - **`.system`**: one of macOS's own items (the clock, Control Center, Wi-Fi), by its module name.
///
/// The text form (`string`) is also the `Codable` form, so a stored or exported layout names items the same way everywhere.
public struct ItemID: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Key: Hashable, Sendable {
        case identifier(String)
        case index(Int)
        case system(module: String)
    }

    /// The owner of every system item. It is the prefix of macOS's own item identifiers (`com.apple.menuextra.clock`).
    public static let systemBundleID = "com.apple.menuextra"

    /// The app that draws the item, or `systemBundleID` for a system item.
    public let bundleID: String
    public let key: Key

    /// A system item is always owned by `systemBundleID`, whatever bundle ID is given with it, so that an ID is equal to the
    /// one its text form gives back.
    public init(bundleID: String, key: Key) {
        if case .system = key {
            self.bundleID = Self.systemBundleID
        } else {
            self.bundleID = bundleID
        }
        self.key = key
    }

    public static func system(_ module: String) -> ItemID {
        ItemID(bundleID: systemBundleID, key: .system(module: module))
    }

    public var isSystem: Bool {
        if case .system = key { return true }
        return false
    }

    /// Whether the text form names this ID again. Some combinations don't: a bundle ID that is `system` or holds `::` with an
    /// identifier (the text reads as a system item or splits in the wrong place), an empty part, and a negative index (a minus sign
    /// isn't in the text form). Nothing Mantel makes is one of them (a bundle ID is a reverse-DNS name, and indices count from 0), but
    /// they can be built, so such an ID is never written: encoding it throws.
    public var isRepresentable: Bool {
        ItemID(string: string) == self
    }

    // MARK: Text form

    private static let systemPrefix = "system:"
    private static let identifierSeparator = "::"
    private static let indexSeparator: Character = "#"

    /// `<bundleID>::<identifier>`, `<bundleID>#<index>` or `system:<module>`.
    public var string: String {
        switch key {
        case .identifier(let identifier): bundleID + Self.identifierSeparator + identifier
        case .index(let index): "\(bundleID)\(Self.indexSeparator)\(index)"
        case .system(let module): Self.systemPrefix + module
        }
    }

    public var description: String { string }

    /// The ID a text form names, or nil when it names none.
    ///
    /// - `system:` at the start: a system item.
    /// - Otherwise the first `::` splits the app from the identifier. (A bundle ID never holds a colon, so the first one is always
    ///   the separator, and the identifier may hold any number of them.)
    /// - Otherwise a trailing `#` and digits is the index.
    /// - Anything else, and any form with an empty part, is nil.
    public init?(string: String) {
        if string.hasPrefix(Self.systemPrefix) {
            let module = String(string.dropFirst(Self.systemPrefix.count))
            guard !module.isEmpty else { return nil }
            self = .system(module)
        } else if let separator = string.range(of: Self.identifierSeparator) {
            let bundleID = String(string[..<separator.lowerBound])
            let identifier = String(string[separator.upperBound...])
            guard !bundleID.isEmpty, !identifier.isEmpty else { return nil }
            self.init(bundleID: bundleID, key: .identifier(identifier))
        } else if let hash = string.lastIndex(of: Self.indexSeparator) {
            let bundleID = String(string[..<hash])
            let digits = string[string.index(after: hash)...]
            guard !bundleID.isEmpty, !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit), let index = Int(digits) else { return nil }
            self.init(bundleID: bundleID, key: .index(index))
        } else {
            return nil
        }
    }

    // MARK: Codable

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let id = ItemID(string: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\"\(text)\" isn't a menu bar item ID.")
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        guard isRepresentable else {
            throw EncodingError.invalidValue(self, EncodingError.Context(
                codingPath: encoder.codingPath, debugDescription: "\"\(string)\" can't be read back as the same menu bar item ID."))
        }
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }

    // MARK: What an identifier is

    /// The identifier if it names the item, or nil: for no identifier, an empty one, and the names AppKit makes up (`_NS:` and a
    /// number), which change from one launch to the next.
    public static func usableIdentifier(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, !raw.hasPrefix("_NS:") else { return nil }
        return raw
    }

    /// The module of one of macOS's own item identifiers: `clock` for `com.apple.menuextra.clock`. Nil for any other identifier.
    public static func systemModule(ofIdentifier identifier: String) -> String? {
        let prefix = systemBundleID + "."
        guard identifier.hasPrefix(prefix) else { return nil }
        let module = String(identifier.dropFirst(prefix.count))
        return module.isEmpty ? nil : module
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
