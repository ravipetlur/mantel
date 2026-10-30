import Foundation
import MKUpdate
import Testing

/// What stops a wrong app from being installed over the running one: the app in the image must be this app (its identifier) at
/// the offered version, which is newer than the running one; its signature must be this app's signer's; and only a newer
/// release is offered.
@Suite("Which app may be installed", .timeLimit(.minutes(2)))
struct IdentityTests {
    let running = VersionNumber("1.1.0")!
    let offered = VersionNumber("1.2.0")!
    let identifier = "com.example.mantel"

    func mismatch(identifier found: String? = "com.example.mantel", version: String? = "1.2.0", offered: VersionNumber? = nil,
                  running: VersionNumber? = nil, expected: String? = nil) -> UpdateFailure? {
        AppIdentity.mismatch(bundleIdentifier: found, shortVersion: version, expectedIdentifier: expected ?? identifier,
                             offered: offered ?? self.offered, running: running ?? self.running)
    }

    @Test func theOfferedAppPasses() {
        #expect(mismatch() == nil)
        #expect(mismatch(version: "2.0.0", offered: VersionNumber("2.0.0")!) == nil)
        #expect(mismatch(version: "1.10.0", offered: VersionNumber("1.10.0")!, running: VersionNumber("1.9.9")!) == nil)
    }

    /// The identifier is exact: another app, the command-line tool's, another spelling, none at all. An app with no identifier of
    /// its own to compare with accepts nothing.
    @Test(arguments: [
        "com.example.other", "com.example.mantel.cli", "COM.EXAMPLE.MANTEL", " com.example.mantel", "", nil,
    ] as [String?])
    func aDifferentIdentifierIsRejected(found: String?) {
        #expect(mismatch(identifier: found) == .appIdentifierMismatch)
    }

    @Test func anEmptyExpectedIdentifierPassesNothing() {
        #expect(mismatch(identifier: "", expected: "") == .appIdentifierMismatch)
    }

    @Test(arguments: [nil, "", "1.2", "1.2.0.0", "1.2.0-beta.1", "v1.2.0", " 1.2.0", "1.2.0 ", "1.02.0", "1.2.1", "1.1.0", "1.10.0"] as [String?])
    func aVersionThatIsNotTheOfferedOneInItsOwnSpellingIsRejected(text: String?) {
        #expect(mismatch(version: text) == .appVersionMismatch)
    }

    /// Never a downgrade, never the same version again, whatever the app says.
    @Test func theOfferedVersionMustBeNewerThanTheRunningOne() {
        #expect(mismatch(version: "1.1.0", offered: VersionNumber("1.1.0")!) == .appVersionMismatch)
        #expect(mismatch(version: "1.0.0", offered: VersionNumber("1.0.0")!) == .appVersionMismatch)
    }

    @Test func theIdentifierIsCheckedBeforeTheVersion() {
        #expect(mismatch(identifier: "com.example.other", version: "9.9.9") == .appIdentifierMismatch)
    }

    // MARK: The signature

    /// `errSecCSReqFailed` is a valid signature of another signer (another team, or ad hoc claiming this identifier); every
    /// other failure is a signature that isn't valid. Only success passes.
    @Test(arguments: [
        (0, nil), (-67050, UpdateFailure.signerMismatch), (-67061, .signatureInvalid), (-67054, .signatureInvalid),
        (-67062, .signatureInvalid), (-67022, .signatureInvalid), (-1, .signatureInvalid), (1, .signatureInvalid),
    ] as [(Int32, UpdateFailure?)])
    func theSignatureStatusSaysWhoSignedIt(status: Int32, failure: UpdateFailure?) {
        #expect(SignatureStatus.failure(forStatus: status) == failure)
    }

    // MARK: Which release is offered

    func version(_ text: String) -> VersionNumber { VersionNumber(text)! }

    @Test(arguments: [
        ("1.1.0", "1.2.0", nil, true), ("1.9.9", "1.10.0", nil, true),
        ("1.1.0", "1.1.0", nil, false), ("1.2.0", "1.1.0", nil, false), ("1.10.0", "1.9.9", nil, false),
        // The skipped version, and anything older than it, isn't offered; a newer one is.
        ("1.1.0", "1.2.0", "1.2.0", false), ("1.1.0", "1.2.0", "1.3.0", false), ("1.1.0", "1.3.0", "1.2.0", true),
        ("1.1.0", "1.2.0", "1.0.5", true),
    ] as [(String, String, String?, Bool)])
    func onlyAStrictlyNewerReleaseIsOffered(current: String, latest: String, skipped: String?, offered: Bool) {
        let release = Releases.make(latest)
        let result = UpdateDecision.offer(current: version(current), latest: release, skipped: skipped.map(version))
        #expect((result != nil) == offered)
    }

    @Test func noReleaseOffersNothing() {
        #expect(UpdateDecision.offer(current: version("1.1.0"), latest: nil, skipped: nil) == nil)
    }

    /// After an update is installed and before the app restarts into it, the version on disk is the current one: what is
    /// already installed is never offered again.
    @Test func theInstalledVersionCountsAsCurrentOnceItIsNewer() {
        #expect(UpdateDecision.currentVersion(running: version("1.2.0"), installed: version("1.2.1")) == version("1.2.1"))
        #expect(UpdateDecision.currentVersion(running: version("1.2.0"), installed: nil) == version("1.2.0"))
        #expect(UpdateDecision.currentVersion(running: version("1.2.1"), installed: version("1.2.0")) == version("1.2.1"))
        let current = UpdateDecision.currentVersion(running: version("1.2.0"), installed: version("1.2.1"))
        #expect(UpdateDecision.offer(current: current, latest: Releases.make("1.2.1"), skipped: nil) == nil)
        #expect(UpdateDecision.offer(current: current, latest: Releases.make("1.3.0"), skipped: nil) != nil)
    }
}
