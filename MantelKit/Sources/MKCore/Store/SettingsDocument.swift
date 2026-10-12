import Foundation

/// The JSON object of a document's contents, as a migration sees it: only inside `SettingsDocument.migrate`, never kept.
public typealias JSONValueTree = [String: Any]

/// One settings file: `<settings folder>/<fileName>`, written by `SettingsStore` as `{ "version": …, "document": … }`.
///
/// Raise `currentVersion` when the file's shape changes in a way the new type can't read, and teach `migrate` to bring
/// the older shapes up to date. A change that only adds a key the type can fall back on (an optional, or a decoder that
/// supplies a default) needs no new version.
public protocol SettingsDocument: Codable, Sendable, Equatable {
    /// The name of the file in the settings folder, such as `settings.json`.
    static var fileName: String { get }
    /// The version `save` writes, 1 for a new document.
    static var currentVersion: Int { get }
    /// Brings the `document` object of a file written as `version` (older than `currentVersion`) to the shape of
    /// `currentVersion`. The default has no migrations: it hands back a document that is current already, and throws
    /// `SettingsMigrationError.noMigration` for any other version, on which the store sets the file aside and loads the
    /// defaults.
    static func migrate(_ document: JSONValueTree, from version: Int) throws -> JSONValueTree
    /// The defaults.
    init()
}

public extension SettingsDocument {
    static func migrate(_ document: JSONValueTree, from version: Int) throws -> JSONValueTree {
        guard version == currentVersion else {
            throw SettingsMigrationError.noMigration(file: fileName, from: version, to: currentVersion)
        }
        return document
    }
}
