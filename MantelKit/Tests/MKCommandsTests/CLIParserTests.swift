import MKCommands
import Testing

@Suite("Command-line parser")
struct CLIParserTests {
    private func parse(_ arguments: String...) -> Result<CLIInvocation, CLIUsageError> {
        CLIParser.parse(arguments)
    }

    private func invocation(_ arguments: [String]) throws -> CLIInvocation {
        try CLIParser.parse(arguments).get()
    }

    private func usageError(_ arguments: [String]) -> String? {
        if case .failure(let error) = CLIParser.parse(arguments) { error.message } else { nil }
    }

    // MARK: Every form of the grammar

    @Test(arguments: [
        (["ping"], MantelCommand.ping),
        (["version"], .version),
        (["diagnostics"], .diagnostics),
        (["settings"], .openSettings(nil)),
        (["settings", "general"], .openSettings(.general)),
        (["settings", "hotkeys"], .openSettings(.hotkeys)),
        (["settings", "permissions"], .openSettings(.permissions)),
        (["settings", "diagnostics"], .openSettings(.diagnostics)),
        (["settings", "about"], .openSettings(.about)),
        (["probe", "inventory"], .probe(.inventory, options: [:])),
        (["probe", "layout-move", "--bundle-id", "com.example.item", "--to", "hidden"],
         .probe(.layoutMove, options: ["bundle-id": "com.example.item", "to": "hidden"])),
    ])
    func everyFormParses(arguments: [String], expected: MantelCommand) throws {
        let parsed = try invocation(arguments)
        #expect(parsed.command == expected)
        #expect(parsed.json == false)
    }

    @Test func everyProbeNameIsAccepted() throws {
        for name in ProbeName.allCases {
            #expect(try invocation(["probe", name.rawValue]).command == .probe(name, options: [:]))
        }
    }

    @Test func allowAnyIsAFlagThatSetsAnOption() throws {
        #expect(try invocation(["probe", "approvals-toggle", "--allow-any"]).command
                == .probe(.approvalsToggle, options: ["allow-any": "true"]))
        #expect(try invocation(["probe", "approvals-toggle", "--bundle-id", "x", "--allow-any"]).command
                == .probe(.approvalsToggle, options: ["bundle-id": "x", "allow-any": "true"]))
        #expect(try invocation(["probe", "approvals-toggle", "--allow-any", "--bundle-id", "x"]).command
                == .probe(.approvalsToggle, options: ["bundle-id": "x", "allow-any": "true"]))
    }

    @Test func aProbeOptionTakesTheWordAfterIt() throws {
        // A value that is a number, or has a single dash, is still a value.
        #expect(try invocation(["probe", "capture", "--display", "-1", "--count", "3"]).command
                == .probe(.capture, options: ["display": "-1", "count": "3"]))
    }

    // MARK: --json

    @Test(arguments: [
        ["--json", "ping"],
        ["ping", "--json"],
        ["settings", "--json", "about"],
        ["probe", "--json", "inventory"],
        ["probe", "inventory", "--json"],
        ["probe", "inventory", "--bundle-id", "x", "--json"],
    ]) func jsonCanBeAnywhere(arguments: [String]) throws {
        #expect(try invocation(arguments).json == true)
    }

    @Test func jsonIsNeverAnOptionOfAProbe() throws {
        let parsed = try invocation(["probe", "inventory", "--json", "--bundle-id", "x"])
        #expect(parsed.command == .probe(.inventory, options: ["bundle-id": "x"]))
        #expect(parsed.json)
    }

    // MARK: Help

    @Test func helpIsNotACommand() {
        // The tool prints the usage and exits 0 for these; `parse` says only that nothing is to be sent.
        for arguments in [["help"], ["--help"], ["-h"], ["--json", "help"]] {
            #expect(CLIParser.isHelpRequest(arguments), "\(arguments) is a request for help")
            #expect(usageError(arguments) == CLIParser.usage)
        }
        for arguments in [[], ["ping"], ["settings", "help"], ["probe", "inventory", "--help"]] {
            #expect(!CLIParser.isHelpRequest(arguments), "\(arguments) is not")
        }
    }

    @Test func usageNamesEveryCommandAndExitCode() {
        let usage = CLIParser.usage
        for word in ["mantel ping", "mantel version", "mantel diagnostics", "mantel settings", "mantel probe",
                     "mantel help", "--json", "--allow-any"] {
            #expect(usage.contains(word), "usage mentions \(word)")
        }
        for page in SettingsPage.allCases {
            #expect(usage.contains(page.rawValue))
        }
        for name in ProbeName.allCases {
            #expect(usage.contains(name.rawValue))
        }
    }

    // MARK: Refusals

    @Test func noArgumentsIsUsage() {
        #expect(CLIParser.parse([]) == .failure(CLIUsageError(message: CLIParser.usage)))
        #expect(CLIParser.parse(["--json"]) == .failure(CLIUsageError(message: CLIParser.usage)))
    }

    @Test func anUnknownProbeListsTheProbeNames() throws {
        let message = try #require(usageError(["probe", "bogus"]))
        #expect(message.contains("bogus"))
        for name in ProbeName.allCases {
            #expect(message.contains(name.rawValue), "the message lists \(name.rawValue)")
        }
    }

    @Test func aProbeWithoutANameListsThem() throws {
        let message = try #require(usageError(["probe"]))
        #expect(message.contains("inventory"))
        let withOptionFirst = try #require(usageError(["probe", "--bundle-id", "x"]))
        #expect(withOptionFirst.contains("inventory"))
    }

    @Test func settingsBogusIsAUsageError() throws {
        let message = try #require(usageError(["settings", "bogus"]))
        #expect(message.contains("bogus"))
        for page in SettingsPage.allCases {
            #expect(message.contains(page.rawValue))
        }
    }

    @Test(arguments: [
        ["bogus"],
        ["Ping"],
        ["ping", "extra"],
        ["version", "1"],
        ["diagnostics", "--all"],
        ["settings", "general", "about"],
        ["probe", "inventory", "stray"],
        ["probe", "inventory", "--bundle-id"],
        ["probe", "inventory", "--bundle-id", "--allow-any"],
        ["probe", "inventory", "--"],
        ["probe", "inventory", "--allow-any", "true"],
        ["probe", "inventory", "-x", "y"],
    ]) func nonsenseIsAUsageError(arguments: [String]) {
        #expect(usageError(arguments) != nil, "\(arguments) is refused")
    }

    @Test func aMissingOptionValueNamesTheOption() throws {
        let message = try #require(usageError(["probe", "inventory", "--bundle-id"]))
        #expect(message.contains("--bundle-id"))
    }
}
