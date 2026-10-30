import Foundation
import MKUpdate

/// Releases for the tests: the shape GitHub's `releases/latest` lists, with synthetic addresses.
enum Releases {
    static func make(_ version: String, notes: String = "Notes.") -> ReleaseInfo {
        let base = "https://example.com/app/releases/download/v\(version)/Mantel-\(version).dmg"
        return ReleaseInfo(
            version: VersionNumber(version)!, notes: notes,
            pageURL: URL(string: "https://example.com/app/releases/tag/v\(version)")!,
            dmg: .init(name: "Mantel-\(version).dmg", size: 1000, url: URL(string: base)!),
            checksum: .init(name: "Mantel-\(version).dmg.sha256", size: 86, url: URL(string: base + ".sha256")!))
    }

    static let current = make("1.2.0")
    static let newer = make("1.3.0")
}
