import Foundation

/// The two protected Apple files that Mantel reads and writes (hiding and arranging).
/// Mantel can't open them on its own: the person picks each one once in an open panel, and `FileGrantStore` keeps a
/// bookmark of it.
public enum FileGrantKind: String, Codable, Sendable, CaseIterable {
    /// `com.apple.MenuBar.plist`: where the order of the menu bar icons is kept.
    case menuBarLayout
    /// `group.com.apple.controlcenter.plist`: the "Allow in the Menu Bar" approvals.
    case controlCenterApprovals

    /// The name of the file, as the person is asked to choose it.
    public var fileName: String {
        switch self {
        case .menuBarLayout: "com.apple.MenuBar.plist"
        case .controlCenterApprovals: "group.com.apple.controlcenter.plist"
        }
    }
}

/// One file the person has picked, kept as a bookmark.
public struct FileGrant: Codable, Sendable, Equatable {
    public let kind: FileGrantKind
    public let bookmark: Data
    /// The path the bookmark resolved to when granted. A bookmark follows a file that moves; this is how a grant for the file
    /// at that path notices that it isn't there any more.
    public let path: String
    public let grantedAt: Date

    public init(kind: FileGrantKind, bookmark: Data, path: String, grantedAt: Date) {
        self.kind = kind
        self.bookmark = bookmark
        self.path = path
        self.grantedAt = grantedAt
    }
}

/// What `FileGrantStore` keeps in `grants.json`: at most one grant of each kind.
public struct GrantsDocument: SettingsDocument {
    public static let fileName = "grants.json"
    public static let currentVersion = 1

    public var grants: [FileGrant]

    public init() {
        grants = []
    }

    public init(grants: [FileGrant]) {
        self.grants = grants
    }
}

public enum FileGrantError: Error, Equatable {
    /// The person chose a file that isn't the one Mantel needs. `expected` and `got` are file names.
    case wrongFile(expected: String, got: String)
    /// The file couldn't be bookmarked (it isn't there, or the system refused). The text says why.
    case bookmarkFailed(String)
    /// There is no usable grant: none was made, or the file is gone or has moved. A stale grant is revoked as it is found,
    /// so the next step is the same in each case, to ask for the file again. `fileName` is the file the grant was for.
    case stale(fileName: String)
}

extension FileGrantError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .wrongFile(let expected, _):
            "That's not the file Mantel needs. Choose \(expected) in the folder that opened."
        case .bookmarkFailed(let reason):
            "Mantel couldn't keep access to that file (\(reason)). Choose it again."
        case .stale(let fileName):
            "Mantel lost access to \(fileName). Choose it again in Settings › Permissions."
        }
    }
}

/// The file a grant must be of: where it is on this Mac, as the paths that are accepted for it.
public struct ExpectedFile: Sendable, Equatable {
    public let kind: FileGrantKind
    /// Absolute paths, in order of preference. The first is the one the open panel is shown. A kind gets more than one
    /// when a macOS version keeps the file somewhere else.
    public let candidates: [String]

    init(kind: FileGrantKind, candidates: [String]) {
        self.kind = kind
        self.candidates = candidates
    }

    /// Where `kind`'s file is under `home` (`~`, or a temporary folder in tests).
    public static func expected(_ kind: FileGrantKind, home: URL) -> ExpectedFile {
        let relative = switch kind {
        case .menuBarLayout:
            "Library/Group Containers/com.apple.MenuBar/Library/Preferences/\(kind.fileName)"
        case .controlCenterApprovals:
            "Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/\(kind.fileName)"
        }
        return ExpectedFile(kind: kind, candidates: [home.appending(path: relative).path(percentEncoded: false)])
    }

    /// The name of the file to choose: the preferred candidate's.
    public var fileName: String {
        candidates.first.map { URL(filePath: $0).lastPathComponent } ?? ""
    }

    /// Whether `url` is one of the candidates, compared with symlinks resolved and the path standardized on both sides:
    /// `~/Library/Group Containers` may be reached through a link, and the open panel hands back either spelling.
    func matches(_ url: URL) -> Bool {
        let chosen = CanonicalPath.of(url)
        return candidates.contains { CanonicalPath.of(URL(filePath: $0)) == chosen }
    }
}
