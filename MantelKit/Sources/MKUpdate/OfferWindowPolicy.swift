/// When the update window opens by itself. A background check that finds an update opens it once per version for as
/// long as the app runs: the person who closed it with Later isn't asked again by the next daily check, but is at the
/// next launch, which makes a new policy. A manual check that finds an update always opens it, since the person asked.
public struct OfferWindowPolicy: Sendable {
    private var shown: Set<VersionNumber> = []

    public init() {}

    /// Whether to open the window for `version` now, which counts as having shown it for later background checks.
    public mutating func shouldShowWindow(for version: VersionNumber, manual: Bool) -> Bool {
        let first = shown.insert(version).inserted
        return manual || first
    }
}
