import Foundation

/// How the layout table names its items.
enum LayoutKeys {
    /// The top-level key of the table of items and their distance from the trailing edge.
    static let trailingPositions = "TrailingItemPreferredPositions"

    /// `status:` for an app's item, `module:` for a system module; anything else is `other`. Only the prefix, which is a
    /// format and not a name.
    static func prefix(of key: String) -> String {
        guard let colon = key.firstIndex(of: ":") else { return "other" }
        let prefix = key[...colon]
        return prefix.count <= 12 ? String(prefix) : "other"
    }

    /// The bundle ID in `status:<bundle ID>::<autosave name>`; nil for any other key.
    static func bundleID(ofStatusKey key: String) -> String? {
        guard key.hasPrefix("status:") else { return nil }
        let rest = key.dropFirst("status:".count)
        guard let end = rest.range(of: "::") else { return nil }
        let bundleID = String(rest[..<end.lowerBound])
        return bundleID.isEmpty ? nil : bundleID
    }
}
