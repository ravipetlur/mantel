import Darwin
import Foundation
import MKCore
import Security

/// Finds out who is on the other end of a connected socket.
public protocol PeerInspecting: Sendable {
    /// What is known of the process that connected `fd`, or nil when nothing can be told.
    func inspect(socket fd: Int32) -> PeerInfo?
}

/// Asks the system: the connecting process's audit token (the kernel records it when the connection is made, and it
/// names that one process, not any later one that has the same pid) leads to its code, whose signature is checked.
///
/// With a `requirement`, the check is also that the code meets it, which the system decides from the code's
/// certificates. Code that doesn't is reported as having no valid signature, and is given no identity. The requirement
/// is what makes the team in `PeerInfo` something the program was signed with and not only something it says. A
/// requirement the system can't read refuses everyone.
public struct CodeSigningInspector: PeerInspecting {
    private let requirement: String?

    /// `requirement` is in the system's requirement language; see `PeerPolicy.requirement(for:)`.
    public init(requirement: String? = nil) {
        self.requirement = requirement
    }

    public func inspect(socket fd: Int32) -> PeerInfo? {
        var token = audit_token_t()
        var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenSize) == 0,
              tokenSize == socklen_t(MemoryLayout<audit_token_t>.size) else { return nil }
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize) == 0 else { return nil }

        let unknown = PeerInfo(pid: pid, signingIdentifier: nil, teamIdentifier: nil, isValidSignature: false,
                               executablePath: nil)
        let attributes = [kSecGuestAttributeAudit: Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)]
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, SecCSFlags(), &guest) == errSecSuccess,
              let code = guest else { return unknown }

        var required: SecRequirement?
        if let requirement, SecRequirementCreateWithString(requirement as CFString, SecCSFlags(), &required) != errSecSuccess {
            Log.error("control", "the requirement for a client can't be read, so no client is let in")
            return unknown
        }

        var origin: SecStaticCode?
        let url = SecCodeCopyStaticCode(code, SecCSFlags(), &origin) == errSecSuccess ? origin.flatMap(Self.url(of:)) : nil
        let path = url?.resolvingSymlinksInPath().path
        let canonicalPath = url.map(CanonicalPath.of)
        // Unsigned code, or code whose signature doesn't hold, is given no identity at all. The check is of the running
        // code, and it fails if the file it came from has changed since it started, so what is then read from that
        // file is what is running.
        guard SecCodeCheckValidity(code, SecCSFlags(), required) == errSecSuccess,
              let origin, let signing = Signing.read(from: origin) else {
            return PeerInfo(pid: pid, signingIdentifier: nil, teamIdentifier: nil, isValidSignature: false,
                            executablePath: path, canonicalPath: canonicalPath)
        }
        return PeerInfo(pid: pid, signingIdentifier: signing.identifier, teamIdentifier: signing.team,
                        isValidSignature: true, executablePath: path, canonicalPath: canonicalPath,
                        codeDirectoryHash: signing.codeDirectoryHash)
    }

    /// The program's file.
    private static func url(of code: SecStaticCode) -> URL? {
        var url: CFURL?
        guard SecCodeCopyPath(code, SecCSFlags(), &url) == errSecSuccess, let url else { return nil }
        return url as URL
    }
}

/// How Mantel itself is signed, which decides whom it will talk to.
public enum OwnSigningReader {
    public static func current() -> OwnSigning {
        var own: SecCode?
        var origin: SecStaticCode?
        var signing: Signing?
        if SecCodeCopySelf(SecCSFlags(), &own) == errSecSuccess, let own,
           SecCodeCopyStaticCode(own, SecCSFlags(), &origin) == errSecSuccess, let origin {
            signing = Signing.read(from: origin)
        }
        let bundleURL = Bundle.main.bundleURL
        // Only a build without a team is held to the tool's hash: a team build checks its clients against the team's certificate.
        let hash = signing?.team == nil ? sealedHelperHash(inAppAt: bundleURL) : nil
        return OwnSigning(bundleIdentifier: Bundle.main.bundleIdentifier ?? signing?.identifier ?? "com.example.mantel",
                          teamIdentifier: signing?.team, bundlePath: CanonicalPath.of(bundleURL), helperCodeDirectoryHash: hash)
    }

    /// The code directory hash of the tool in the app at `appURL`, as the app's own signature has it sealed.
    ///
    /// The app is checked first, with the check of everything nested in it (`kSecCSCheckNestedCode`): its signature, the seal
    /// of its resources, and for each piece of code in it (the tool is one) that the code is the one the seal names. Only an
    /// app that passes has anything read from it, and what is read is not the tool's file but the app's seal: the hash that the
    /// app's resource directory records for the tool (`files2`, then the tool's place, then `cdhash`), taken from the same
    /// validated code. So a tool that was swapped for another, even one with a perfectly good signature of its own, is not the
    /// one the app sealed: the app doesn't pass, and there is no hash. The hash is the seal's, so a tool swapped after the check
    /// still has another hash than the one it is compared with.
    ///
    /// The resource directory comes with the system's internal signing information (`kSecCSInternalInformation`), whose keys
    /// aren't documented. If macOS stops giving it, or gives it another shape, there is no hash, and no tool of an ad hoc build is
    /// let in until this is updated: the check fails closed.
    ///
    /// Nil when the app has no valid signature, when anything in it was changed after signing, or when it seals no tool.
    static func sealedHelperHash(inAppAt appURL: URL) -> String? {
        var app: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &app) == errSecSuccess, let app,
              SecStaticCodeCheckValidity(app, SecCSFlags(rawValue: kSecCSCheckNestedCode), nil) == errSecSuccess else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(app, SecCSFlags(rawValue: kSecCSInternalInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let resources = values["ResourceDirectory"] as? [String: Any],
              let files = resources["files2"] as? [String: Any],
              let entry = files[helperPathInResources] as? [String: Any],
              let hash = entry["cdhash"] as? Data, !hash.isEmpty else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// The tool's place as the seal names it: below the app's `Contents` folder.
    private static let helperPathInResources = String(OwnSigning.helperPathInBundle.dropFirst("Contents/".count))
}

/// The identifier, team and code directory hash a signature names.
private struct Signing {
    let identifier: String?
    /// Nil for a signature made ad hoc, which has no team.
    let team: String?
    /// The code directory hash, in lowercase hex.
    let codeDirectoryHash: String?

    static func read(from code: SecStaticCode) -> Signing? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any] else { return nil }
        let team = values[kSecCodeInfoTeamIdentifier as String] as? String
        let hash = (values[kSecCodeInfoUnique as String] as? Data).map { $0.map { String(format: "%02x", $0) }.joined() }
        return Signing(identifier: values[kSecCodeInfoIdentifier as String] as? String,
                       team: team?.isEmpty == false ? team : nil, codeDirectoryHash: hash)
    }
}
