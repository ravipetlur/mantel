import Foundation
import MKCore
import MKUpdate
import Security

/// The checks on a downloaded release that come from macOS: Gatekeeper's assessment of the disk image and of the app, the
/// app's identity from its Info.plist, and its code signature, held against this running app's own designated
/// requirement. Behind a protocol so the install can be run against fakes. Every check throws the `UpdateFailure` that
/// says what was wrong, and passes by returning.
nonisolated protocol CodeVerifying: Sendable {
    /// macOS accepts the disk image as a notarized download (`spctl --assess --type install`).
    func assessImage(at image: URL) async throws
    /// macOS accepts the app to run (`spctl --assess --type execute`).
    func assessApp(at app: URL) async throws
    /// The app's bundle identifier is `expectedIdentifier` and its version is `offered`, which is newer than `running`.
    func checkIdentity(of app: URL, expectedIdentifier: String, offered: VersionNumber, running: VersionNumber) throws
    /// The app's signature is valid (strictly, with every architecture and every nested code), and it satisfies the
    /// designated requirement of the running app.
    func checkSignature(of app: URL) throws
}

nonisolated struct CodeVerifier: CodeVerifying {
    private static let spctl = "/usr/sbin/spctl"

    // MARK: Gatekeeper

    /// `SecAssessment`, the API behind `spctl`, has no header in the macOS 27 SDK, so Apple's own `spctl` is run and its
    /// exit status judged: 0 is accepted, anything else (or a tool that can't run) is rejected, so a check that can't
    /// be made never passes.
    func assessImage(at image: URL) async throws {
        try await assess(image, type: "install", rejection: .imageRejected)
    }

    func assessApp(at app: URL) async throws {
        try await assess(app, type: "execute", rejection: .appRejected)
    }

    private func assess(_ url: URL, type: String, rejection: UpdateFailure) async throws {
        let result: ProcessRunner.Result
        do {
            result = try await ProcessRunner.run(Self.spctl, arguments: ["--assess", "--type", type, url.path(percentEncoded: false)])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.update.warning("The Gatekeeper check (\(type)) couldn't run: \(error.localizedDescription)")
            throw rejection
        }
        guard result.status == 0 else {
            Log.update.warning("Gatekeeper rejected the \(type) assessment (spctl status \(result.status)): \(DiskImage.excerpt(result.output))")
            throw rejection
        }
        Log.update.info("Gatekeeper accepted the \(type) assessment")
    }

    // MARK: Identity

    func checkIdentity(of app: URL, expectedIdentifier: String, offered: VersionNumber, running: VersionNumber) throws {
        let info = Bundle(url: app)?.infoDictionary
        let identifier = info?["CFBundleIdentifier"] as? String
        let version = info?["CFBundleShortVersionString"] as? String
        if let failure = AppIdentity.mismatch(bundleIdentifier: identifier, shortVersion: version,
                                              expectedIdentifier: expectedIdentifier, offered: offered, running: running) {
            Log.update.warning("The app in the image isn't the offered one: \(failure) (identifier \(identifier ?? "none"), version \(version ?? "none"))")
            throw failure
        }
    }

    // MARK: Signature

    /// One strict validation of the app's static code, held to the designated requirement of this running app. The flags
    /// are the ones tested on macOS 27: every architecture, strict validation of the bundle's structure, and the code nested
    /// in it. The requirement is read from `SecCodeCopySelf` and not from a path: whatever signed this app (a Developer ID
    /// certificate, so the same team and identifier) must have signed the new one, and no team is named in the source.
    /// An ad-hoc signed app, even one that claims this identifier, doesn't satisfy it. The status tells the two failures
    /// apart (`SignatureStatus`): a requirement that isn't met is another signer, anything else is a signature that isn't
    /// valid.
    func checkSignature(of app: URL) throws {
        var created: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(app as CFURL, SecCSFlags(), &created)
        guard createStatus == errSecSuccess, let code = created else {
            Log.update.warning("The app's code couldn't be read (OSStatus \(createStatus))")
            throw UpdateFailure.signatureInvalid
        }
        guard let requirement = Self.runningAppRequirement() else {
            // No requirement to hold it to, so nothing can be said about who signed it.
            throw UpdateFailure.signerMismatch
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode))
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        if let failure = SignatureStatus.failure(forStatus: status) {
            Log.update.warning("The app's signature check failed: \(failure) (OSStatus \(status))")
            throw failure
        }
        Log.update.info("The app's signature is valid and satisfies this app's designated requirement")
    }

    /// The designated requirement of the running app itself (`SecCodeCopySelf`), nil when it can't be had.
    private static func runningAppRequirement() -> SecRequirement? {
        var running: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        let selfStatus = SecCodeCopySelf(SecCSFlags(), &running)
        guard selfStatus == errSecSuccess, let running else {
            Log.update.warning("This app's own code couldn't be read (OSStatus \(selfStatus))")
            return nil
        }
        let staticStatus = SecCodeCopyStaticCode(running, SecCSFlags(), &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            Log.update.warning("This app's own static code couldn't be read (OSStatus \(staticStatus))")
            return nil
        }
        let requirementStatus = SecCodeCopyDesignatedRequirement(staticCode, SecCSFlags(), &requirement)
        guard requirementStatus == errSecSuccess, let requirement else {
            Log.update.warning("This app's designated requirement couldn't be read (OSStatus \(requirementStatus))")
            return nil
        }
        return requirement
    }
}
