import Foundation

/// Why a settings file written by an older Mantel couldn't be brought up to date. The file is set aside (kept in Backups) and
/// the defaults are used, so what the message says is what happened to the person's settings.
public enum SettingsMigrationError: Error, Equatable, LocalizedError {
    /// This Mantel doesn't know how to update the file from version `from` to version `to`.
    case noMigration(file: String, from: Int, to: Int)
    /// The update was tried and failed; `reason` says how.
    case failed(file: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .noMigration(let file, let from, let to):
            "Mantel can't update \(file) from version \(from) to \(to). It was set aside, and the defaults are used."
        case .failed(let file, let reason):
            "Mantel couldn't update \(file): \(reason). It was set aside, and the defaults are used."
        }
    }
}
