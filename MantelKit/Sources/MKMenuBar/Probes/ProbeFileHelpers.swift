import Foundation
import MKCommands
import MKCore

/// What a property list value looks like, without what it says: the probes that read the approvals and layout files report
/// their shape, never their values.
enum PlistShape {
    static func typeName(_ value: PlistValue) -> String {
        switch value {
        case .string: "string"
        case .integer: "integer"
        case .real: "real"
        case .bool: "bool"
        case .date: "date"
        case .data: "data"
        case .array: "array"
        case .dictionary: "dictionary"
        }
    }

    /// The type, and for a dictionary or an array what is in it, down to `maxDepth` levels: a dictionary's key names with the
    /// shape of each value, an array's length and the shape of its first element and the types of all of them. A value that
    /// isn't a container is only its type's name. A dictionary of more than `maxKeys` keys is cut, and says so.
    static func describe(_ value: PlistValue, depth: Int = 0, maxDepth: Int = 3, maxKeys: Int = 300) -> JSONValue {
        switch value {
        case .dictionary(let entries):
            guard depth < maxDepth else { return .object(["type": .string("dictionary"), "count": .number(Double(entries.count))]) }
            var described: [String: JSONValue] = [:]
            for key in entries.keys.sorted().prefix(maxKeys) {
                described[key] = describe(entries[key]!, depth: depth + 1, maxDepth: maxDepth, maxKeys: maxKeys)
            }
            var object: [String: JSONValue] = ["type": .string("dictionary"), "count": .number(Double(entries.count)),
                                               "entries": .object(described)]
            if entries.count > maxKeys { object["truncated"] = .bool(true) }
            return .object(object)
        case .array(let elements):
            var object: [String: JSONValue] = ["type": .string("array"), "count": .number(Double(elements.count)),
                                               "elementTypes": .array(Set(elements.map(typeName)).sorted().map(JSONValue.string))]
            if let first = elements.first, depth < maxDepth {
                object["first"] = describe(first, depth: depth + 1, maxDepth: maxDepth, maxKeys: maxKeys)
            }
            return .object(object)
        default:
            return .string(typeName(value))
        }
    }

    /// Whether `text` is a key, or a string value, anywhere inside the value.
    static func contains(_ value: PlistValue, string text: String) -> Bool {
        switch value {
        case .string(let string): string == text
        case .dictionary(let entries): entries.contains { $0.key == text || contains($0.value, string: text) }
        case .array(let elements): elements.contains { contains($0, string: text) }
        default: false
        }
    }
}

/// Where an app's "Allow in the Menu Bar" switch is in `trackedApplications`, and what it would be flipped to.
///
/// The shape of that key is for `approvals-read` to find out on this Mac, so this reads three shapes it could be and flips
/// the first it finds: a dictionary keyed by bundle ID whose value is a flag, a dictionary of that app holding a flag whose
/// name has "allow" in it, or an array of dictionaries one of which names the app and holds such a flag. An app it can't
/// find, or find a flag for, is nil, and the probe changes nothing.
enum ApprovalsEditor {
    struct Flip: Equatable {
        /// The whole `trackedApplications` value with the app's flag flipped.
        let value: PlistValue
        /// Where the flag is, for the report.
        let path: String
        /// What the flag was.
        let wasAllowed: Bool
    }

    static func flipped(_ tracked: PlistValue, bundleID: String) -> Flip? {
        switch tracked {
        case .dictionary(var entries):
            guard let entry = entries[bundleID], let flip = flipFlag(in: entry) else { return nil }
            entries[bundleID] = flip.value
            return Flip(value: .dictionary(entries), path: "trackedApplications[\(bundleID)]\(flip.path)", wasAllowed: flip.wasAllowed)
        case .array(var elements):
            for (index, element) in elements.enumerated() {
                guard case .dictionary(let fields) = element, fields.values.contains(.string(bundleID)),
                      let flip = flipFlag(in: element) else { continue }
                elements[index] = flip.value
                return Flip(value: .array(elements), path: "trackedApplications[\(index)]\(flip.path)", wasAllowed: flip.wasAllowed)
            }
            return nil
        default:
            return nil
        }
    }

    private struct FlagFlip {
        let value: PlistValue
        let path: String
        let wasAllowed: Bool
    }

    /// A flag that is the value itself, or the first flag inside a dictionary whose name says "allow".
    private static func flipFlag(in value: PlistValue) -> FlagFlip? {
        switch value {
        case .bool(let flag): return FlagFlip(value: .bool(!flag), path: "", wasAllowed: flag)
        case .integer(let number) where number == 0 || number == 1:
            return FlagFlip(value: .integer(1 - number), path: "", wasAllowed: number == 1)
        case .dictionary(var fields):
            for name in fields.keys.sorted() where name.lowercased().contains("allow") {
                switch fields[name] {
                case .bool(let flag)?:
                    fields[name] = .bool(!flag)
                    return FlagFlip(value: .dictionary(fields), path: ".\(name)", wasAllowed: flag)
                case .integer(let number)? where number == 0 || number == 1:
                    fields[name] = .integer(1 - number)
                    return FlagFlip(value: .dictionary(fields), path: ".\(name)", wasAllowed: number == 1)
                default: continue
                }
            }
            return nil
        default:
            return nil
        }
    }
}

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
