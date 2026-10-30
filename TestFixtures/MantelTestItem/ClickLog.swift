import Foundation

/// What MantelTestItem writes down when one of its first two items is clicked: which item, what kind of click it was, and when. A program
/// that clicks the item reads it to see what the item received, which is not always what was sent.
///
/// The file is `clicks.json` in the test item's own folder in Application Support, and holds the last click only:
/// `{"item":"one","kind":"left","at":1700000000.25}`, the time being seconds since 1970. It is replaced whole, so a reader finds the old
/// record or the new one and never half of one.
struct ClickLog {
    typealias Kind = ClickEventRule.Kind

    /// The file's name inside the folder.
    static let fileName = "clicks.json"

    private let folder: URL

    /// - Parameter folder: where the file is kept. By default the test item's own folder in the person's Application Support.
    init(folder: URL = ClickLog.defaultFolder) {
        self.folder = folder
    }

    /// `~/Library/Application Support/MantelTestItem`.
    static var defaultFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return support.appending(path: "MantelTestItem", directoryHint: .isDirectory)
    }

    var fileURL: URL {
        folder.appending(path: Self.fileName, directoryHint: .notDirectory)
    }

    /// What the file holds for a click.
    static func record(item: String, kind: Kind, at date: Date) -> Data {
        struct Record: Encodable {
            let item: String
            let kind: String
            let at: Double
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // The record is three plain values, which always encode.
        return (try? encoder.encode(Record(item: item, kind: kind.rawValue, at: date.timeIntervalSince1970))) ?? Data()
    }

    /// Writes the click, replacing what was there. A failure is ignored: the test item has nobody to tell, and a reader that finds no record
    /// says so.
    func write(item: String, kind: Kind, at date: Date = Date()) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.record(item: item, kind: kind, at: date).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("MantelTestItem couldn't write its click log: %@", error.localizedDescription)
        }
    }
}
