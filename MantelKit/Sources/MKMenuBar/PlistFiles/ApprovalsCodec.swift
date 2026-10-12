import Foundation
import MKCore

/// What macOS keeps of the "Allow in the Menu Bar" switches: under `trackedApplications` in the file of the Control Center group, a
/// property list kept as a blob. Its root is an array with an entry for each app that has a switch:
///
///     { isAllowed: Bool, menuItemLocations: [ { bundle: { _0: <bundle ID> } } | { adhocBinary: { _0: { relative: <path> } } } ] }
///
/// `isAllowed` is true while the app's icon may be on the menu bar. System Settings writes the whole array again, in another order, on
/// every change, so a place is never found by its position: an app's entry is the one element in which `menuItemLocations`, any
/// element, `bundle`, `_0` reaches the app's bundle ID (`KeyPathStep.matchingPath`), wherever it is. An app with no entry, or an entry
/// that names it only by a program's path (`adhocBinary`), can't be found by its bundle ID.
///
/// The codec is the nested one (a blob that is a property list, read whole and written again in its own format) under the ID
/// `approvals`, with what is known of this list's shape on top.
public struct ApprovalsCodec: PlistBlobCodec {
    /// The top-level key of the file that holds the list.
    public static let key = "trackedApplications"
    /// The ID a journal entry names this codec by, and the app registers it under.
    public static let id = PlistBlobCodecID(rawValue: "approvals")

    /// The way from an entry to the bundle ID of its app, for any of its locations.
    static let wayToBundleID: [KeyPathStep] = [.key("menuItemLocations"), .anyElement, .key("bundle"), .key("_0")]

    private let nested = NestedPlistCodec()

    public init() {}

    public func value(at path: PlistKeyPath, in blob: Data) throws -> PlistValue? {
        try nested.value(at: path, in: blob)
    }

    public func setting(_ value: PlistValue?, at path: PlistKeyPath, in blob: Data) throws -> Data {
        try nested.setting(value, at: path, in: blob)
    }

    /// Where an app's switch is, from the top of the list: its entry, found by the app's bundle ID, and the flag in it. There are no
    /// steps before them: the root of the blob is the array.
    public static func flagPath(for bundleID: String) -> PlistKeyPath {
        [.matchingPath(path: wayToBundleID, value: bundleID), .key("isAllowed")]
    }
}

/// One entry of the list, as far as Mantel reads it.
struct ApprovalsEntry: Equatable, Sendable {
    /// The bundle IDs among the entry's places, in order (an entry can have more than one; one that has none is named by a program).
    let bundleIDs: [String]
    /// Whether the app's icon is allowed; nil when the entry has no flag that is a true or false.
    let isAllowed: Bool?
}

/// The list as it is read: whether it is the shape Mantel knows, and what it says.
enum ApprovalsList {
    /// The entries of a decoded list, in the order it holds them; nil when it isn't the shape Mantel edits: not an array of dictionaries,
    /// or (for a list that has entries) not one of them with a list of places.
    static func entries(in list: PlistValue?) -> [ApprovalsEntry]? {
        guard case .array(let elements)? = list else { return nil }
        var entries: [ApprovalsEntry] = []
        var hasPlaces = false
        for element in elements {
            guard case .dictionary(let fields) = element else { return nil }
            var ids: [String] = []
            if case .array(let locations)? = fields["menuItemLocations"] {
                hasPlaces = true
                for case .dictionary(let location) in locations {
                    if case .dictionary(let bundle)? = location["bundle"], case .string(let id)? = bundle["_0"] { ids.append(id) }
                }
            }
            var allowed: Bool?
            if case .bool(let flag)? = fields["isAllowed"] { allowed = flag }
            entries.append(ApprovalsEntry(bundleIDs: ids, isAllowed: allowed))
        }
        // A list with nothing in it says nothing about its shape; one that has entries and none that name their places isn't this list.
        guard elements.isEmpty || hasPlaces else { return nil }
        return entries
    }
}
