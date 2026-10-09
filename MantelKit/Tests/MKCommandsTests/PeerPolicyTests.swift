@testable import MKCommands
import Testing

@Suite("Peer policy")
struct PeerPolicyTests {
    static let team = "ABCDE12345"
    static let teamBuild = OwnSigning(bundleIdentifier: "com.example.mantel", teamIdentifier: team,
                                      bundlePath: "/Applications/Mantel.app")
    static let adHocBuild = OwnSigning(bundleIdentifier: "com.example.mantel", teamIdentifier: nil,
                                       bundlePath: "/Users/someone/Build/Mantel.app")

    private static func peer(_ identifier: String?, team: String? = PeerPolicyTests.team, valid: Bool = true,
                             path: String? = "/Applications/Mantel.app/Contents/MacOS/mantel") -> PeerInfo {
        PeerInfo(pid: 4242, signingIdentifier: identifier, teamIdentifier: team, isValidSignature: valid,
                 executablePath: path)
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

        // A build signed ad hoc, which has no team: the tool must be the one inside the running app.
        Case(name: "ad hoc build accepts its tool inside the app", own: adHocBuild,
             peer: peer("com.example.mantel.cli", team: nil,
                        path: "/Users/someone/Build/Mantel.app/Contents/MacOS/mantel"),
             expected: .accept),
        Case(name: "ad hoc build rejects the same tool outside the app", own: adHocBuild,
             peer: peer("com.example.mantel.cli", team: nil, path: "/tmp/mantel"),
             expected: notATool("com.example.mantel.cli")),
        Case(name: "ad hoc build rejects a folder that only starts like the app", own: adHocBuild,
             peer: peer("com.example.mantel.cli", team: nil,
                        path: "/Users/someone/Build/Mantel.app-copy/Contents/MacOS/mantel"),
             expected: notATool("com.example.mantel.cli")),
        Case(name: "ad hoc build rejects the app's path itself", own: adHocBuild,
             peer: peer("com.example.mantel.cli", team: nil, path: "/Users/someone/Build/Mantel.app"),
             expected: notATool("com.example.mantel.cli")),
        Case(name: "ad hoc build rejects an unknown path", own: adHocBuild,
             peer: peer("com.example.mantel.cli", team: nil, path: nil),
             expected: notATool("com.example.mantel.cli")),
        Case(name: "ad hoc build rejects another identifier inside the app", own: adHocBuild,
             peer: peer("com.example.other", team: nil,
                        path: "/Users/someone/Build/Mantel.app/Contents/MacOS/other"),
             expected: notATool("com.example.other")),
        Case(name: "ad hoc build rejects the app's own identifier", own: adHocBuild,
             peer: peer("com.example.mantel", team: nil,
                        path: "/Users/someone/Build/Mantel.app/Contents/MacOS/Mantel"),
             expected: notATool("com.example.mantel")),
        Case(name: "ad hoc build rejects an invalid signature inside the app", own: adHocBuild,
             peer: peer(nil, team: nil, valid: false,
                        path: "/Users/someone/Build/Mantel.app/Contents/MacOS/mantel"),
             expected: invalid),
    ]

    @Test(arguments: cases) func decides(_ testCase: Case) {
        #expect(PeerPolicy.decide(testCase.peer, own: testCase.own) == testCase.expected)
    }

    @Test func aBundlePathWithATrailingSlashStillMatchesItsTool() {
        let own = OwnSigning(bundleIdentifier: "com.example.mantel", teamIdentifier: nil,
                             bundlePath: "/Users/someone/Build/Mantel.app/")
        let tool = Self.peer("com.example.mantel.cli", team: nil,
                             path: "/Users/someone/Build/Mantel.app/Contents/MacOS/mantel")
        #expect(PeerPolicy.decide(tool, own: own) == .accept)
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
