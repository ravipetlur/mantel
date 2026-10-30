import Foundation
import MKCore
import MKLayout

/// Reads macOS's order table (`TrailingItemPreferredPositions` in the menu bar's preferences) through its grant.
///
/// The table is read the way it is written, through `cfprefsd`: the service holds what is current, and the file behind it is written a
/// moment later (and is not where a reading app may look at it). So this is the table as macOS has it now.
public struct LayoutTableReader: Sendable {
    private let access: PlistFileAccess
    private let grants: FileGrantStore

    public init(access: PlistFileAccess, grants: FileGrantStore) {
        self.access = access
        self.grants = grants
    }

    /// The table now.
    ///
    /// A file with no table (a Mac whose order has never been set) has an empty one. A distance that isn't a number is left out.
    ///
    /// - Throws: `FileGrantError.stale` when the file isn't granted (or is gone, or has moved: the grant is then removed), and
    ///   `PlistAccessError` when `cfprefsd` has a table that isn't one (not a dictionary).
    public func read() async throws -> LayoutTableSnapshot {
        // Asking for the grant checks that it still leads to the file; `cfprefsd` is then asked for what the file's domain holds.
        let file = try await grants.withAccess(.menuBarLayout) { $0 }
        guard let table = try await access.value(at: [], key: LayoutKeys.trailingPositions, in: file) else {
            return LayoutTableSnapshot(distances: [:])
        }
        guard case .dictionary(let entries) = table else { throw PlistAccessError.notADictionary }
        var distances: [String: Double] = [:]
        for (key, value) in entries {
            switch value {
            case .integer(let number): distances[key] = Double(number)
            case .real(let number): distances[key] = number
            default: continue
            }
        }
        return LayoutTableSnapshot(distances: distances)
    }
}
