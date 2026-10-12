import Foundation

/// Where the running Mantel.app is, which decides whether it can hide icons: macOS only allows that for an app that runs
/// from `/Applications`.
public enum InstallLocation {
    public enum Verdict: Equatable, Sendable {
        /// Directly in `/Applications`.
        case applications
        /// Directly in the person's own `~/Applications`.
        case userApplications
        /// Run from a read-only copy that macOS makes of an app opened from a quarantined download (App Translocation). The
        /// app can't be moved from there; the person has to drag the original into Applications.
        case translocated
        /// Anywhere else, with the folder it is in.
        case elsewhere(String)
    }

    /// Where Mantel is moved to.
    public static let destination = URL(filePath: "/Applications/Mantel.app", directoryHint: .isDirectory)

    /// The verdict for the app at `bundleURL`, for the current user's `~/Applications`.
    public static func verdict(for bundleURL: URL) -> Verdict {
        verdict(for: bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// The verdict with `home` as the home folder, for tests. Only the folder the bundle is directly in counts:
    /// `/Applications/Utilities/Mantel.app` is "elsewhere". The bundle is read by its canonical path (`CanonicalPath`), so a
    /// link in `/Applications` that leads to a build folder is judged by where it leads; nothing needs to exist.
    public static func verdict(for bundleURL: URL, home: URL) -> Verdict {
        let folder = (CanonicalPath.of(bundleURL) as NSString).deletingLastPathComponent
        if folder.contains("/AppTranslocation/") { return .translocated }
        if folder == CanonicalPath.of(applicationsFolder) { return .applications }
        if folder == CanonicalPath.of(home.appending(path: "Applications", directoryHint: .isDirectory)) {
            return .userApplications
        }
        return .elsewhere(folder)
    }

    private static let applicationsFolder = URL(filePath: "/Applications", directoryHint: .isDirectory)

    /// Whether two URLs are the same bundle: the same canonical path, which follows links, resolves `..` and drops a trailing
    /// slash. Used before an app is replaced, so that the running one is never taken for another copy.
    public static func isSameBundle(_ one: URL, _ other: URL) -> Bool {
        CanonicalPath.of(one) == CanonicalPath.of(other)
    }

    /// Why the running Mantel must not be moved to `/Applications`.
    public enum MoveRefusal: Equatable, Sendable {
        /// The bundle this copy started from is no longer there: it has been moved already, and this process is running from
        /// where it went (its own idea of its path is still the old one).
        case alreadyMoved
        /// The Mantel in the destination is this one, or is running. Replacing it would put a running app in the Trash.
        case destinationIsRunning
        /// Where this process's executable is couldn't be found out, or isn't inside an app, so it can't be told whether the
        /// copy in the destination is this one.
        case cannotConfirmRunningCopy
    }

    /// Whether the move of the app at `source` to `destination` must be refused, and why. It fails closed: what it can't
    /// check, it refuses.
    /// - Parameters:
    ///   - source: the bundle this process was started from, as the process knows it (it doesn't change if the bundle is moved).
    ///   - sourceExists: whether there is a bundle at `source` now.
    ///   - currentExecutable: where this process's executable is now, as the system says (it does follow a move). Nil when
    ///     the system couldn't say, which is a refusal: this is how a running copy that has already been moved into the
    ///     destination is told from one that hasn't.
    ///   - runningBundles: the bundles of the apps that are running.
    public static func moveRefusal(source: URL, sourceExists: Bool, currentExecutable: URL?, runningBundles: [URL],
                                   destination: URL = destination) -> MoveRefusal? {
        guard sourceExists else { return .alreadyMoved }
        if isSameBundle(source, destination) { return .destinationIsRunning }
        if runningBundles.contains(where: { isSameBundle($0, destination) }) { return .destinationIsRunning }
        guard let executable = currentExecutable, let current = bundle(containingExecutable: executable) else {
            return .cannotConfirmRunningCopy
        }
        if isSameBundle(current, destination) { return .destinationIsRunning }
        return nil
    }

    /// The app an executable is in: the nearest folder above it that ends in `.app`. Nil for one that isn't in an app.
    public static func bundle(containingExecutable executable: URL) -> URL? {
        var folder = executable.standardizedFileURL.deletingLastPathComponent()
        while folder.path(percentEncoded: false) != "/" {
            if folder.pathExtension == "app" {
                return URL(filePath: path(of: folder), directoryHint: .isDirectory)
            }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    /// A folder's path without the slash a directory URL ends in (and not for the root, which is only a slash).
    private static func path(of folder: URL) -> String {
        let path = folder.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
