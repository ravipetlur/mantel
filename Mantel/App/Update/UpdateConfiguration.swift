import Foundation
import MKCore
import MKUpdate

/// What the updater needs from the build. The updater is inert unless the build names an update repository: the Info.plist
/// key `MantelUpdateRepository` (from `MANTEL_UPDATE_REPO`, which only release builds set) holds a non-empty
/// `owner/repo`. Without one `current()` is nil, so nothing makes an `UpdateCenter`: no menu item, no Settings rows, no
/// timer, no network.
struct UpdateConfiguration {
    static let repositoryInfoKey = "MantelUpdateRepository"

    /// The `owner/repo` the build names, for the log.
    let repository: String
    /// `releases/latest` of that repository.
    let endpoint: URL
    /// The running version, `CFBundleShortVersionString`.
    let currentVersion: VersionNumber

    /// `Mantel/<version>`, which GitHub needs on every request.
    var userAgent: String { "Mantel/\(currentVersion)" }

    /// The build's configuration, or nil when it is inert: no repository (the usual case, and silent), a repository that
    /// isn't `owner/repo`, or a version that isn't `X.Y.Z` (both of which are logged, since they're a mistake in the build).
    static func current(bundle: Bundle = .main) -> UpdateConfiguration? {
        let named = (bundle.object(forInfoDictionaryKey: repositoryInfoKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !named.isEmpty else { return nil }
        guard let endpoint = ReleaseFeed.endpoint(repository: named) else {
            Log.update.warning("The update repository isn't owner/repo, so updates are off: \(named)")
            return nil
        }
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard let version = VersionNumber(shortVersion) else {
            Log.update.warning("The app's version isn't X.Y.Z, so updates are off: \(shortVersion)")
            return nil
        }
        return UpdateConfiguration(repository: named, endpoint: endpoint, currentVersion: version)
    }
}
