@testable import MKCommands
import Testing

@Suite("Peer policy", .timeLimit(.minutes(2)))
struct PeerPolicyTests {
    static let team = "ABCDE12345"
    static let teamBuild = OwnSigning(bundleIdentifier: "com.example.mantel", teamIdentifier: team,
                                      bundlePath: "/Applications/Mantel.app")
    /// What the app's own signature seals for its tool.
    static let sealedHash = "4492163eb73551a3e248cecb36d2578283bd98ff"
    static let adHocBuild = OwnSigning(bundleIdentifier: "com.example.mantel", teamIdentifier: nil,
                                       bundlePath: "/Users/someone/Build/Mantel.app", helperCodeDirectoryHash: sealedHash)
    /// Where the tool is in `adHocBuild`'s app, canonical.
    static let helperPath = adHocBuild.helperCanonicalPath

    private static func peer(_ identifier: String?, team: String? = PeerPolicyTests.team, valid: Bool = true,
                             path: String? = "/Applications/Mantel.app/Contents/Helpers/mantel",
                             hash: String? = PeerPolicyTests.sealedHash) -> PeerInfo {
        PeerInfo(pid: 4242, signingIdentifier: identifier, teamIdentifier: team, isValidSignature: valid,
                 executablePath: path, canonicalPath: path, codeDirectoryHash: hash)
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let own: OwnSigning
        let peer: PeerInfo
        let expected: PeerDecision
        var testDescription: String { name }
    }

    static func notATool(_ identifier: String) -> PeerDecision { .reject("Not a Mantel tool: \(identifier)") }
    static let invalid = PeerDecision.reject("Unsigned or invalid client")

    static let cases: [Case] = [
        // A build signed with a team.
        Case(name: "team build accepts its own tool", own: teamBuild, peer: peer("com.example.mantel.cli"),
             expected: .accept),
        Case(name: "team build accepts its tool from anywhere", own: teamBuild,
             peer: peer("com.example.mantel.cli", path: "/usr/local/bin/mantel"), expected: .accept),
        Case(name: "team build rejects another team", own: teamBuild,
             peer: peer("com.example.mantel.cli", team: "ZZZZZ99999"), expected: notATool("com.example.mantel.cli")),
        Case(name: "team build rejects no team", own: teamBuild,
             peer: peer("com.example.mantel.cli", team: nil), expected: notATool("com.example.mantel.cli")),
        Case(name: "team build rejects another identifier", own: teamBuild, peer: peer("com.apple.Terminal"),
             expected: notATool("com.apple.Terminal")),
        Case(name: "team build rejects the app's own identifier", own: teamBuild, peer: peer("com.example.mantel"),
             expected: notATool("com.example.mantel")),
        Case(name: "team build rejects a longer identifier", own: teamBuild, peer: peer("com.example.mantel.cli.evil"),
             expected: notATool("com.example.mantel.cli.evil")),
        Case(name: "team build rejects a tool kind it doesn't know", own: teamBuild,
             peer: peer("com.example.mantel.mcp"), expected: notATool("com.example.mantel.mcp")),
        Case(name: "team build rejects an invalid signature", own: teamBuild,
             peer: peer(nil, valid: false), expected: invalid),
        Case(name: "team build rejects an invalid signature that claims the right names", own: teamBuild,
             peer: peer("com.example.mantel.cli", valid: false), expected: invalid),
        Case(name: "team build rejects a valid signature with no identifier", own: teamBuild,
             peer: peer(nil), expected: notATool("unknown")),

        // A build signed ad hoc, which has no team: the tool must be the one the running app seals.
        Case(name: "ad hoc build accepts its sealed tool", own: adHocBuild,
             peer: peer("com.example.mantel.cli", team: nil, path: helperPath), expected: .accept),
        Case(name: "ad hoc build rejects the same tool outside the app", own: adHocBuild,
             peer: peer("com.example.mantel.cli", team: nil, path: "/tmp/mantel"),
             expected: notATool("com.example.mantel.cli")),
        Case(name: "ad hoc build rejects a folder that only starts like the app", own: adHocBuild,
             peer: peer("com.example.mantel.cli", team: nil,
                        path: "/Users/someone/Build/Mantel.app-copy/Contents/Helpers/mantel"),
             expected: notATool("com.example.mantel.cli")),
        Case(name: "ad hoc build rejects the app's path itself", own: adHocBuild,
             peer: peer("com.example.mantel.cli", team: nil, path: "/Users/someone/Build/Mantel.app"),
             expected: notATool("com.example.mantel.cli")),
        Case(name: "ad hoc build rejects another program in the app's Helpers", own: adHocBuild,
             peer: peer("com.example.mantel.cli", team: nil, path: "/Users/someone/Build/Mantel.app/Contents/Helpers/other"),
             expected: notATool("com.example.mantel.cli")),
        Case(name: "ad hoc build rejects a program in the place the tool used to be", own: adHocBuild,
             peer: peer("com.example.mantel.cli", team: nil, path: "/Users/someone/Build/Mantel.app/Contents/MacOS/mantel"),
             expected: notATool("com.example.mantel.cli")),
        Case(name: "ad hoc build rejects an unknown path", own: adHocBuild,
             peer: peer("com.example.mantel.cli", team: nil, path: nil),
             expected: notATool("com.example.mantel.cli")),
        Case(name: "ad hoc build rejects another identifier at the tool's place", own: adHocBuild,
             peer: peer("com.example.other", team: nil, path: helperPath), expected: notATool("com.example.other")),
        Case(name: "ad hoc build rejects the app's own identifier", own: adHocBuild,
             peer: peer("com.example.mantel", team: nil, path: helperPath), expected: notATool("com.example.mantel")),
        Case(name: "ad hoc build rejects an invalid signature at the tool's place", own: adHocBuild,
             peer: peer(nil, team: nil, valid: false, path: helperPath), expected: invalid),
    ]

    @Test(arguments: cases) func decides(_ testCase: Case) {
        #expect(PeerPolicy.decide(testCase.peer, own: testCase.own) == testCase.expected)
    }

    @Test func aBundlePathWithATrailingSlashStillMatchesItsTool() {
        let own = OwnSigning(bundleIdentifier: "com.example.mantel", teamIdentifier: nil,
                             bundlePath: "/Users/someone/Build/Mantel.app/", helperCodeDirectoryHash: Self.sealedHash)
        let tool = Self.peer("com.example.mantel.cli", team: nil, path: own.helperCanonicalPath)
        #expect(own.helperCanonicalPath == Self.helperPath)
        #expect(PeerPolicy.decide(tool, own: own) == .accept)
    }

    // MARK: A build signed ad hoc

    private static let ownTool = peer("com.example.mantel.cli", team: nil, path: helperPath)

    @Test func adHocAcceptsSealedHelperOnly() {
        #expect(PeerPolicy.decide(Self.ownTool, own: Self.adHocBuild) == .accept)
        // Each of the three things has to be right: who it says it is, where it is, and what it is.
        let wrongName = Self.peer("com.example.other", team: nil, path: Self.helperPath)
        let wrongPlace = Self.peer("com.example.mantel.cli", team: nil, path: "/Users/someone/Elsewhere/mantel")
        let wrongHash = Self.peer("com.example.mantel.cli", team: nil, path: Self.helperPath, hash: "00")
        for impostor in [wrongName, wrongPlace, wrongHash] {
            #expect(PeerPolicy.decide(impostor, own: Self.adHocBuild) != .accept)
        }
    }

    @Test func adHocRejectsCopyOutsideBundle() {
        // A copy of the sealed tool, byte for byte, so it has the hash and the identifier; it is somewhere else.
        for path in ["/usr/local/bin/mantel", "/tmp/mantel", "/Users/someone/Build/Mantel.app/Contents/MacOS/mantel",
                     "/Applications/Mantel.app/Contents/Helpers/mantel"] {
            let copy = Self.peer("com.example.mantel.cli", team: nil, path: path)
            #expect(PeerPolicy.decide(copy, own: Self.adHocBuild) == .reject("Not a Mantel tool: com.example.mantel.cli"), "\(path)")
        }
        // A path that is only spelled like the tool's: the policy compares canonical paths, and the inspector makes one.
        let spelledOtherwise = Self.peer("com.example.mantel.cli", team: nil, path: "/Users/someone/Build/Mantel.app/Contents/Helpers/../Helpers/mantel")
        #expect(PeerPolicy.decide(spelledOtherwise, own: Self.adHocBuild) != .accept)
    }

    @Test func adHocRejectsWrongHash() {
        // The right place and a good signature of its own, but not the tool the app sealed: one swapped into the app.
        let swapped = Self.peer("com.example.mantel.cli", team: nil, path: Self.helperPath,
                                hash: "8bea6a923ee0954371334c5361b393048c2d0038")
        #expect(PeerPolicy.decide(swapped, own: Self.adHocBuild) == .reject("Not a Mantel tool: com.example.mantel.cli"))
        // Not even for a hash that only starts like the sealed one.
        let prefix = Self.peer("com.example.mantel.cli", team: nil, path: Self.helperPath, hash: String(Self.sealedHash.dropLast(2)))
        #expect(PeerPolicy.decide(prefix, own: Self.adHocBuild) != .accept)
        #expect(PeerPolicy.decide(Self.peer("com.example.mantel.cli", team: nil, path: Self.helperPath,
                                            hash: Self.sealedHash.uppercased()), own: Self.adHocBuild) != .accept,
                "the hash is written in lowercase, and is compared as written")
    }

    @Test func adHocRejectsUnknownHash() {
        // The peer's hash couldn't be read.
        let unread = Self.peer("com.example.mantel.cli", team: nil, path: Self.helperPath, hash: nil)
        #expect(PeerPolicy.decide(unread, own: Self.adHocBuild) == .reject("Not a Mantel tool: com.example.mantel.cli"))

        // The app couldn't say what it sealed (its signature, or something nested in it, didn't check out): nothing matches
        // that, not even a peer that has no hash either.
        let unsealed = OwnSigning(bundleIdentifier: "com.example.mantel", teamIdentifier: nil,
                                  bundlePath: "/Users/someone/Build/Mantel.app", helperCodeDirectoryHash: nil)
        #expect(PeerPolicy.decide(Self.ownTool, own: unsealed) == .reject("Not a Mantel tool: com.example.mantel.cli"))
        #expect(PeerPolicy.decide(unread, own: unsealed) == .reject("Not a Mantel tool: com.example.mantel.cli"))
    }

    @Test func teamRuleUnchanged() {
        // A team build goes by the team's certificate: where the tool is, and what its hash is, are not asked.
        let tool = Self.peer("com.example.mantel.cli", path: "/usr/local/bin/mantel", hash: nil)
        #expect(PeerPolicy.decide(tool, own: Self.teamBuild) == .accept)
        let unlocated = PeerInfo(pid: 1, signingIdentifier: "com.example.mantel.cli", teamIdentifier: Self.team,
                                 isValidSignature: true, executablePath: nil)
        #expect(PeerPolicy.decide(unlocated, own: Self.teamBuild) == .accept)
        // Its own sealed tool is accepted too, and the identifier and the team are still what decide.
        let sealed = OwnSigning(bundleIdentifier: "com.example.mantel", teamIdentifier: Self.team,
                                bundlePath: "/Applications/Mantel.app", helperCodeDirectoryHash: Self.sealedHash)
        #expect(PeerPolicy.decide(Self.peer("com.example.mantel.cli", path: sealed.helperCanonicalPath), own: sealed) == .accept)
        #expect(PeerPolicy.decide(Self.peer("com.example.mantel.cli", team: "ZZZZZ99999"), own: sealed)
                == .reject("Not a Mantel tool: com.example.mantel.cli"))
        #expect(PeerPolicy.decide(Self.peer("com.apple.Terminal"), own: sealed) == .reject("Not a Mantel tool: com.apple.Terminal"))
        #expect(PeerPolicy.decide(Self.peer("com.example.mantel.cli", valid: false), own: Self.teamBuild)
                == .reject("Unsigned or invalid client"))
    }

    @Test func theAcceptedIdentifiersAreTheAppsIdentifierWithCli() {
        #expect(PeerPolicy.acceptedIdentifiers(for: Self.teamBuild) == ["com.example.mantel.cli"])
        let renamed = OwnSigning(bundleIdentifier: "com.yourname.mantel", teamIdentifier: nil, bundlePath: "/x/Mantel.app")
        #expect(PeerPolicy.acceptedIdentifiers(for: renamed) == ["com.yourname.mantel.cli"])
    }

    // MARK: The requirement a team build puts on a client

    @Test func aTeamBuildRequiresItsToolSignedByItsTeam() {
        #expect(PeerPolicy.requirement(for: Self.teamBuild)
                == #"identifier "com.example.mantel.cli" and anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345""#)
    }

    @Test func anAdHocBuildHasNoRequirementAndKeepsThePathRule() {
        #expect(PeerPolicy.requirement(for: Self.adHocBuild) == nil)
    }

    @Test func theRequirementFollowsTheAppsIdentifierAndTeam() {
        let own = OwnSigning(bundleIdentifier: "com.yourname.mantel", teamIdentifier: "ZZZZZ99999", bundlePath: "/x/Mantel.app")
        #expect(PeerPolicy.requirement(for: own)
                == #"identifier "com.yourname.mantel.cli" and anchor apple generic and certificate leaf[subject.OU] = "ZZZZZ99999""#)
    }

    @Test func quotesAndBackslashesInTheNamesCannotChangeTheRequirement() {
        let own = OwnSigning(bundleIdentifier: #"x" or anchor apple \"#, teamIdentifier: #"T" or "1"="1"#, bundlePath: "/x")
        let text = PeerPolicy.requirement(for: own)
        #expect(text == #"identifier "x\" or anchor apple \\.cli" and anchor apple generic and certificate leaf[subject.OU] = "T\" or \"1\"=\"1""#)
    }

    @Test func severalAcceptedIdentifiersAreAlternatives() {
        #expect(PeerPolicy.requirementText(identifiers: ["b.cli", "a.mcp"], team: "TEAM")
                == #"(identifier "a.mcp" or identifier "b.cli") and anchor apple generic and certificate leaf[subject.OU] = "TEAM""#)
    }
}
