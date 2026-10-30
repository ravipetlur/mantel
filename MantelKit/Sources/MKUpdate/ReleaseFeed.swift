import Foundation

/// A release the updater can install: its version, notes, page and the two files it needs.
public struct ReleaseInfo: Equatable, Sendable {
    /// One file of a release.
    public struct Asset: Equatable, Sendable {
        public let name: String
        /// The size in bytes the release lists.
        public let size: Int
        public let url: URL

        public init(name: String, size: Int, url: URL) {
            self.name = name
            self.size = size
            self.url = url
        }
    }

    public let version: VersionNumber
    /// The release notes, as Markdown. Empty when the release has none.
    public let notes: String
    /// The release's web page.
    public let pageURL: URL
    /// `Mantel-<version>.dmg`.
    public let dmg: Asset
    /// `Mantel-<version>.dmg.sha256`: `<hash>  <file name>` for the disk image.
    public let checksum: Asset

    public init(version: VersionNumber, notes: String, pageURL: URL, dmg: Asset, checksum: Asset) {
        self.version = version
        self.notes = notes
        self.pageURL = pageURL
        self.dmg = dmg
        self.checksum = checksum
    }
}

/// Reads the answer of GitHub's `releases/latest` endpoint.
public enum ReleaseFeed {
    /// The release in `json`, or nil when it isn't one to install: not JSON of the right shape, a draft or a
    /// pre-release, a tag that isn't `vX.Y.Z`, or assets other than exactly one `Mantel-<version>.dmg` and one
    /// `Mantel-<version>.dmg.sha256` for the tag's version. Other assets and fields are ignored. Links must be
    /// `https`, and a file needs a size above zero.
    ///
    /// The release's own `digest` fields aren't read: the `.sha256` file is where the checksum comes from.
    public static func latest(from json: Data) -> ReleaseInfo? {
        guard let release = try? JSONDecoder().decode(RawRelease.self, from: json) else { return nil }
        // The endpoint leaves drafts and pre-releases out; a result marked as one is ignored all the same.
        guard release.draft != true, release.prerelease != true else { return nil }
        guard let tag = release.tagName, let version = VersionNumber(tag) else { return nil }
        guard let pageURL = httpsURL(release.pageURL) else { return nil }

        let assets = (release.assets ?? []).compactMap(\.value)
        let dmgName = "Mantel-\(version).dmg"
        guard let dmg = onlyAsset(named: dmgName, in: assets),
              let checksum = onlyAsset(named: dmgName + ".sha256", in: assets)
        else { return nil }
        return ReleaseInfo(version: version, notes: release.body ?? "", pageURL: pageURL, dmg: dmg, checksum: checksum)
    }

    /// The asset with exactly this name, when there's exactly one of that name and it has a size and an https link.
    /// A second asset of the name, even a malformed one, makes the choice ambiguous.
    private static func onlyAsset(named name: String, in assets: [RawAsset]) -> ReleaseInfo.Asset? {
        let named = assets.filter { $0.name == name }
        guard named.count == 1, let asset = named.first,
              let size = asset.size, size > 0, let url = httpsURL(asset.downloadURL)
        else { return nil }
        return ReleaseInfo.Asset(name: name, size: size, url: url)
    }

    private static func httpsURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), url.scheme?.lowercased() == "https",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    // MARK: The JSON

    /// The fields read. Missing ones are nil; one of the wrong type fails the decoding.
    private struct RawRelease: Decodable {
        let tagName: String?
        let draft: Bool?
        let prerelease: Bool?
        let body: String?
        let pageURL: String?
        let assets: [Lossy<RawAsset>]?

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", draft, prerelease, body, pageURL = "html_url", assets
        }
    }

    /// An asset's fields, each read on its own: a field that's missing or of the wrong type is nil, so an odd asset
    /// that isn't one of ours can't spoil the rest.
    private struct RawAsset: Decodable {
        let name: String?
        let size: Int?
        let downloadURL: String?

        private enum CodingKeys: String, CodingKey {
            case name, size, downloadURL = "browser_download_url"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try? container.decode(String.self, forKey: .name)
            size = try? container.decode(Int.self, forKey: .size)
            downloadURL = try? container.decode(String.self, forKey: .downloadURL)
        }
    }

    /// A value that's nil, not an error, when it can't be decoded (an array entry that isn't an object, say).
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }
}
