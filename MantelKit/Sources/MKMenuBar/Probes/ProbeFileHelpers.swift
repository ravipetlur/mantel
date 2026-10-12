import Foundation
import MKCommands
import MKCore

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
