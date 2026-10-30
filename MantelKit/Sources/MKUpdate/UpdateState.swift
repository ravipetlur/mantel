import Foundation
import MKCore

/// What the updater remembers between launches, in `update-state.json` in Mantel's folder, kept by the settings store like the
/// other files. It is state and not a setting: the person never chooses it.
public struct UpdateState: SettingsDocument {
    public static let fileName = "update-state.json"
    public static let currentVersion = 1

    /// When the last check was made, a failed one included.
    public var lastCheck: Date?
    /// The version the person chose to skip, as `X.Y.Z`. A background check doesn't offer it, or anything older.
    public var skippedVersion: String?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case lastCheck, skippedVersion
    }

    // A value that can't be read is read as missing, so that a file written by a later version still opens.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastCheck = container.decodeLeniently(Date.self, forKey: .lastCheck, category: "update")
        skippedVersion = container.decodeLeniently(String.self, forKey: .skippedVersion, category: "update")
    }
}
