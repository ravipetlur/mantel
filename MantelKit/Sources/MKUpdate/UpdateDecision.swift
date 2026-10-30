/// Whether a release is worth offering.
public enum UpdateDecision {
    /// The version a check compares with: the running one, or the one installed on disk since, if that is newer. After an
    /// update is installed and before the app restarts into it, the running version is the old one, and a check must not
    /// offer the version that is already installed.
    public static func currentVersion(running: VersionNumber, installed: VersionNumber?) -> VersionNumber {
        guard let installed else { return running }
        return max(running, installed)
    }

    /// The release to offer, or nil. Only a version strictly newer than the running one is offered, so never the same
    /// version and never a downgrade. The version the person chose to skip, and anything older than it, isn't offered;
    /// a newer one is. No release at all offers nothing.
    public static func offer(current: VersionNumber, latest: ReleaseInfo?, skipped: VersionNumber?) -> ReleaseInfo? {
        guard let latest, latest.version > current else { return nil }
        if let skipped, latest.version <= skipped { return nil }
        return latest
    }
}
