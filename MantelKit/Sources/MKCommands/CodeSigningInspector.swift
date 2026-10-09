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
        let path = SecCodeCopyStaticCode(code, SecCSFlags(), &origin) == errSecSuccess ? origin.flatMap(Self.path(of:)) : nil
        // Unsigned code, or code whose signature doesn't hold, is given no identity at all. The check is of the running
        // code, and it fails if the file it came from has changed since it started, so what is then read from that
        // file is what is running.
        guard SecCodeCheckValidity(code, SecCSFlags(), required) == errSecSuccess,
              let origin, let signing = Signing.read(from: origin) else {
            return PeerInfo(pid: pid, signingIdentifier: nil, teamIdentifier: nil, isValidSignature: false,
                            executablePath: path)
        }
        return PeerInfo(pid: pid, signingIdentifier: signing.identifier, teamIdentifier: signing.team,
                        isValidSignature: true, executablePath: path)
    }

    /// The program's file, with symbolic links resolved the way `OwnSigningReader` resolves the app's own path.
    private static func path(of code: SecStaticCode) -> String? {
        var url: CFURL?
        guard SecCodeCopyPath(code, SecCSFlags(), &url) == errSecSuccess, let url else { return nil }
        return (url as URL).resolvingSymlinksInPath().path
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
        return OwnSigning(bundleIdentifier: Bundle.main.bundleIdentifier ?? signing?.identifier ?? "com.example.mantel",
                          teamIdentifier: signing?.team,
                          bundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path)
    }
}

/// The identifier and team a signature names.
private struct Signing {
    let identifier: String?
    /// Nil for a signature made ad hoc, which has no team.
    let team: String?

    static func read(from code: SecStaticCode) -> Signing? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any] else { return nil }
        let team = values[kSecCodeInfoTeamIdentifier as String] as? String
        return Signing(identifier: values[kSecCodeInfoIdentifier as String] as? String,
                       team: team?.isEmpty == false ? team : nil)
    }
}
