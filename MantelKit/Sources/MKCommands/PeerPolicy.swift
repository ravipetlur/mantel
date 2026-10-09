import Foundation

/// What the app learned about the process on the other end of a connection.
public struct PeerInfo: Sendable, Equatable {
    public let pid: pid_t
    /// The identifier the program is signed with. Nil when it is unsigned or its signature isn't valid.
    public let signingIdentifier: String?
    public let teamIdentifier: String?
    public let isValidSignature: Bool
    public let executablePath: String?

    public init(pid: pid_t, signingIdentifier: String?, teamIdentifier: String?, isValidSignature: Bool,
                executablePath: String?) {
        self.pid = pid
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.isValidSignature = isValidSignature
        self.executablePath = executablePath
    }
}

/// What the app knows of how it is itself signed, which decides who it will talk to.
public struct OwnSigning: Sendable, Equatable {
    public let bundleIdentifier: String
    /// Nil for a build signed ad hoc, which has no team.
    public let teamIdentifier: String?
    /// The running Mantel.app.
    public let bundlePath: String

    public init(bundleIdentifier: String, teamIdentifier: String?, bundlePath: String) {
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.bundlePath = bundlePath
    }
}

public enum PeerDecision: Sendable, Equatable {
    case accept
    /// With what to tell the client.
    case reject(String)
}

/// Who may use the control socket: Mantel's own tools, and nothing else.
///
/// - A build signed with a team accepts a program signed by that team with one of the accepted identifiers. What the
///   program says about its team is only a claim until the system has checked it against the certificate, so the
///   inspector is given `requirement(for:)` to check the program against, and a program that fails it is "invalid".
/// - A build signed ad hoc has no team to go by, and anyone can sign a program ad hoc under any identifier, so it also
///   wants the program to be a file inside the running app. (Changing the files in the app takes the person's own
///   permission.)
public enum PeerPolicy {
    /// The identifiers of the tools that may connect: for now the command-line tool's, the app's with `.cli` after it.
    public static func acceptedIdentifiers(for own: OwnSigning) -> Set<String> {
        ["\(own.bundleIdentifier).cli"]
    }

    /// The code signing requirement a client of a team build must meet, in the system's requirement language, or nil for
    /// a build that has no team. It says that the program has one of the accepted identifiers and was signed with a
    /// certificate from Apple's chain whose organizational unit (the team) is Mantel's own. The system checks this
    /// against the certificate, not against what the program says about itself.
    public static func requirement(for own: OwnSigning) -> String? {
        guard let team = own.teamIdentifier else { return nil }
        return requirementText(identifiers: acceptedIdentifiers(for: own), team: team)
    }

    static func requirementText(identifiers: Set<String>, team: String) -> String {
        let named = identifiers.sorted().map { "identifier \"\(quoted($0))\"" }
        let who = named.count == 1 ? named[0] : "(" + named.joined(separator: " or ") + ")"
        return "\(who) and anchor apple generic and certificate leaf[subject.OU] = \"\(quoted(team))\""
    }

    /// `text` as the inside of a quoted string in the requirement language, so no name can end the string early.
    private static func quoted(_ text: String) -> String {
        text.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
    }

    public static func decide(_ peer: PeerInfo, own: OwnSigning) -> PeerDecision {
        guard peer.isValidSignature else { return .reject("Unsigned or invalid client") }
        let notATool = PeerDecision.reject("Not a Mantel tool: \(peer.signingIdentifier ?? "unknown")")

        guard let identifier = peer.signingIdentifier, acceptedIdentifiers(for: own).contains(identifier) else {
            return notATool
        }
        if let team = own.teamIdentifier {
            return peer.teamIdentifier == team ? .accept : notATool
        }
        let bundle = own.bundlePath.hasSuffix("/") ? own.bundlePath : own.bundlePath + "/"
        guard let path = peer.executablePath, path.hasPrefix(bundle) else { return notATool }
        return .accept
    }
}
