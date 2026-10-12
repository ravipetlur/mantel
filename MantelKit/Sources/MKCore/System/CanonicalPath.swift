import Foundation

/// The one way Mantel writes a path so that two spellings of the same file compare equal.
public enum CanonicalPath {
    /// The path with every symbolic link in it resolved (`/tmp` and `/var` are links into `/private`, and a folder in the home
    /// folder may be one too), `..` and a trailing slash taken out.
    ///
    /// It works for a file that isn't there: the part that exists is resolved, and what comes after it is kept as it is. A grant
    /// for a file that has gone still has to be found, to say so.
    ///
    /// (`URL.resolvingSymlinksInPath()` is not this: it turns `/private/var` back into `/var`, so a path that was resolved
    /// by the system and one resolved by Foundation disagree.)
    public static func of(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path(percentEncoded: false)) {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var base = existing.path(percentEncoded: false)
        if let resolved = realpath(base, nil) {
            base = String(cString: resolved)
            free(resolved)
        }
        return rest.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
    }
}
