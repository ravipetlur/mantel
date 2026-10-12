import Foundation
import MKCommands
import MKCore

/// The two protected files (the "Allow in the Menu Bar" list and the menu bar layout), reached through their grants.
enum GrantedFile {
    /// Where the granted file is, from the grant; nil when none was made.
    static func url(of kind: FileGrantKind, in grants: FileGrantStore) async -> URL? {
        await grants.grant(for: kind).map { URL(filePath: $0.path) }
    }

    /// What to tell the person when there is no grant.
    static func missing(_ kind: FileGrantKind) -> String {
        switch kind {
        case .controlCenterApprovals:
            "Mantel has no access to the “Allow in the Menu Bar” file yet. Choose it in Settings › Permissions, then run this probe again."
        case .menuBarLayout:
            "Mantel has no access to the menu bar layout file yet. Choose it in Settings › Permissions, then run this probe again."
        }
    }

    /// The top-level keys of the file, read through its grant.
    static func readTopLevel(_ kind: FileGrantKind, grants: FileGrantStore, plist: PlistFileAccess) async throws -> [String: PlistValue] {
        try await grants.withAccess(kind) { url in try plist.readTopLevel(url) }
    }
}
