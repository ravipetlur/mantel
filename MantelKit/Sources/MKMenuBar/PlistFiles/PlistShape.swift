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
