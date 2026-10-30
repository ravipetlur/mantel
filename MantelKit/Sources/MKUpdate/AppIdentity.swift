/// Whether the app inside the downloaded image is the app that was offered.
public enum AppIdentity {
    /// Why an app with these Info.plist values isn't the offered update to the running app, or nil when it is.
    ///
    /// - Its bundle identifier must equal `expectedIdentifier` (the running app's), exactly: a missing or empty one, or
    ///   one that differs in any way, is `appIdentifierMismatch`. The identifier is checked first.
    /// - Its `CFBundleShortVersionString` must be exactly `X.Y.Z` and equal `offered`, else `appVersionMismatch`.
    /// - `offered` must be newer than `running`, else `appVersionMismatch`: never a downgrade, never the same version
    ///   again, whatever the app says.
    public static func mismatch(
        bundleIdentifier: String?, shortVersion: String?, expectedIdentifier: String, offered: VersionNumber,
        running: VersionNumber
    ) -> UpdateFailure? {
        guard !expectedIdentifier.isEmpty, bundleIdentifier == expectedIdentifier else { return .appIdentifierMismatch }
        // The text has to be the version's own spelling: no `v`, no spaces, no suffix.
        guard let shortVersion, let version = VersionNumber(shortVersion), version.description == shortVersion,
              version == offered, offered > running
        else { return .appVersionMismatch }
        return nil
    }
}
