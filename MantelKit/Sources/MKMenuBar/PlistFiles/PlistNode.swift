import Foundation
import MKCore

/// A property list value as the codecs look at one: all of what a property list holds, and the reference to an object that a keyed
/// archive keeps (`uid`), which `PlistValue` can't hold.
indirect enum PlistNode: Equatable {
    case null, bool(Bool), integer(Int), real(Double), date, data, string(String), uid(Int)
    case array([PlistNode])
    case dictionary([String: PlistNode])

    /// How deep a value is followed, and how many values are read: a blob that is deeper or bigger is cut (what is past a limit is
    /// `null`).
    static let maximumDepth = 24
    static let maximumNodes = 200_000

    /// A property list read from bytes.
    static func parse(_ blob: Data) throws -> PlistNode {
        if blob.starts(with: BinaryPlist.magic) {
            let plist = try BinaryPlist(blob)
            var budget = maximumNodes
            return try node(of: plist.top, in: plist, depth: 0, budget: &budget)
        }
        var format = PropertyListSerialization.PropertyListFormat.binary
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: blob, options: [], format: &format)
        } catch {
            throw PlistBlobCodecError.notAPropertyList
        }
        var budget = maximumNodes
        return node(of: object, depth: 0, budget: &budget)
    }

    private static func node(of object: Int, in plist: BinaryPlist, depth: Int, budget: inout Int) throws -> PlistNode {
        budget -= 1
        guard budget > 0, depth <= maximumDepth else { return .null }
        switch plist.objects[object] {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .integer(let number): return .integer(number)
        case .real(let number): return .real(number)
        case .date: return .date
        case .data: return .data
        case .string(let text): return .string(text)
        case .uid(let value): return .uid(value)
        case .array(let refs), .set(let refs):
            return .array(try refs.map { try node(of: $0, in: plist, depth: depth + 1, budget: &budget) })
        case .dictionary(let keys, let values):
            var entries: [String: PlistNode] = [:]
            for (key, value) in zip(keys, values) {
                guard let name = plist.string(key) else { continue }
                entries[name] = try node(of: value, in: plist, depth: depth + 1, budget: &budget)
            }
            return .dictionary(entries)
        }
    }

    private static func node(of object: Any, depth: Int, budget: inout Int) -> PlistNode {
        budget -= 1
        guard budget > 0, depth <= maximumDepth else { return .null }
        switch object {
        case let text as String: return .string(text)
        case is Date: return .date
        case is Data: return .data
        case let array as [Any]: return .array(array.map { node(of: $0, depth: depth + 1, budget: &budget) })
        case let dictionary as [String: Any]:
            return .dictionary(dictionary.mapValues { node(of: $0, depth: depth + 1, budget: &budget) })
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return CFNumberIsFloatType(number as CFNumber) ? .real(number.doubleValue) : .integer(number.intValue)
        default:
            // The reference of a keyed archive, which has no value of its own to read here.
            return CFCopyTypeIDDescription(CFGetTypeID(object as CFTypeRef)) as String? == "CFKeyedArchiverUID" ? .uid(-1) : .null
        }
    }

    // MARK: Looking inside

    /// The keyed archive's list of objects, when this is the top of one.
    var archiveObjects: [PlistNode]? {
        guard case .dictionary(let top) = self, case .string? = top["$archiver"], case .array(let objects)? = top["$objects"] else {
            return nil
        }
        return objects
    }
}
