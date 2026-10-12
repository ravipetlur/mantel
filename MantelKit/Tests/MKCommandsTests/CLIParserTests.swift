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

    @Test func showTargets() throws {
        #expect(try invocation(["show", "hidden"]).command == .show(.hidden))
        #expect(try invocation(["show", "all"]).command == .show(.all))
        // `none` on the command line is the case `.nothing`.
        #expect(try invocation(["show", "none"]).command == .show(.nothing))
        let parsed = try invocation(["show", "all", "--json"])
        #expect(parsed.command == .show(.all))
        #expect(parsed.json)
        #expect(parsed.confirmation == nil)
        let needs = "“show” needs one of: hidden, all, none. Run “mantel help” for usage."
        #expect(usageError(["show"]) == needs)
        #expect(usageError(["show", "some"]) == needs)
        #expect(usageError(["show", "nothing"]) == needs)
        #expect(usageError(["show", "Hidden"]) == needs)
        #expect(usageError(["show", "hidden", "all"]) == needs)
    }

    @Test func focusChanges() throws {
        #expect(try invocation(["focus", "on"]).command == .focus(.on))
        #expect(try invocation(["focus", "off"]).command == .focus(.off))
        #expect(try invocation(["focus", "toggle"]).command == .focus(.toggle))
        #expect(try invocation(["--json", "focus", "toggle"]).json)
        let needs = "“focus” needs one of: on, off, toggle. Run “mantel help” for usage."
        #expect(usageError(["focus"]) == needs)
        #expect(usageError(["focus", "yes"]) == needs)
        #expect(usageError(["focus", "on", "off"]) == needs)
    }

    @Test func resetWithYesHasNoConfirmation() throws {
        let parsed = try invocation(["reset", "--yes"])
        #expect(parsed.command == .reset)
        #expect(parsed.confirmation == nil)
        // `--yes` can stand anywhere, as `--json` can.
        #expect(try invocation(["--yes", "reset"]).confirmation == nil)
        let both = try invocation(["reset", "--json", "--yes"])
        #expect(both.command == .reset)
        #expect(both.json)
        #expect(both.confirmation == nil)
    }

    @Test func resetWithoutYesAsks() throws {
        let parsed = try invocation(["reset"])
        #expect(parsed.command == .reset)
        #expect(parsed.confirmation == "Reset the menu bar? Mantel shows every icon, puts back what it changed, and restarts macOS's menu bar. [y/N] ")
        #expect(try invocation(["reset", "--json"]).confirmation == parsed.confirmation)
        // Only a reset asks.
        for arguments in [["ping"], ["version"], ["refresh"], ["engine"], ["show", "all"], ["focus", "off"], ["settings"], ["probe", "inventory"]] {
            #expect(try invocation(arguments).confirmation == nil, "\(arguments)")
        }
        #expect(usageError(["reset", "now"]) == "“reset” takes no arguments, but got “now”. Run “mantel help” for usage.")
    }

    @Test func yesOnlyWithReset() {
        let refused = "“--yes” only goes with “reset”. Run “mantel help” for usage."
        for arguments in [["show", "hidden", "--yes"], ["ping", "--yes"], ["--yes", "engine"], ["refresh", "--yes"], ["focus", "on", "--yes"],
                          ["settings", "about", "--yes"], ["probe", "inventory", "--yes"], ["diagnostics", "--yes"]] {
            #expect(usageError(arguments) == refused, "\(arguments)")
        }
        // A command that is wrong in its own right is told so first.
        #expect(usageError(["show", "--yes"]) == "“show” needs one of: hidden, all, none. Run “mantel help” for usage.")
        #expect(usageError(["bogus", "--yes"]) == "“bogus” isn't a command. Run “mantel help” for usage.")
    }

    @Test func engineTakesNoArguments() throws {
        #expect(try invocation(["engine"]).command == .engine)
        #expect(try invocation(["engine", "--json"]).json)
        #expect(usageError(["engine", "all"]) == "“engine” takes no arguments, but got “all”. Run “mantel help” for usage.")
        // Nor does refresh.
        #expect(try invocation(["refresh"]).command == .refresh)
        #expect(usageError(["refresh", "now"]) == "“refresh” takes no arguments, but got “now”. Run “mantel help” for usage.")
    }

    @Test func everyProbeNameIsAccepted() throws {
        for name in ProbeName.allCases {
            #expect(try invocation(["probe", name.rawValue]).command == .probe(name, options: [:]))
        }
    }

    @Test func saveBaselineAndCompareAreFlagsToo() throws {
        #expect(try invocation(["probe", "approvals-decode", "--save-baseline"]).command
                == .probe(.approvalsDecode, options: ["save-baseline": "true"]))
        #expect(try invocation(["probe", "approvals-decode", "--compare", "--save-baseline"]).command
                == .probe(.approvalsDecode, options: ["compare": "true", "save-baseline": "true"]))
        // A switch takes no value, so the word after it is the next option, and an option that needs a value still does.
        #expect(try invocation(["probe", "approvals-flip", "--flag-path", "k:allowed", "--codec", "flip", "--runs", "3"]).command
                == .probe(.approvalsFlip, options: ["flag-path": "k:allowed", "codec": "flip", "runs": "3"]))
        #expect(usageError(["probe", "approvals-decode", "--compare", "--compare"])
                == "The option “--compare” is given twice. Run “mantel help” for usage.")
        #expect(usageError(["probe", "approvals-flip", "--flag-path"])
                == "The option “--flag-path” needs a value. Run “mantel help” for usage.")
    }

    @Test func aMatchPathWithStarsAndSlashesIsOneValue() throws {
        // The write test's line: a path with `*` in it is a value like any other, and is not mistaken for an option.
        #expect(try invocation(["probe", "approvals-flip", "--match-path", "k:menuItemLocations/*/k:bundle/k:_0", "--flag-path", "k:isAllowed",
                                "--codec", "nested", "--runs", "5"]).command
                == .probe(.approvalsFlip, options: ["match-path": "k:menuItemLocations/*/k:bundle/k:_0", "flag-path": "k:isAllowed",
                                                    "codec": "nested", "runs": "5"]))
        #expect(usageError(["probe", "approvals-flip", "--match-path"]) == "The option “--match-path” needs a value. Run “mantel help” for usage.")
        // The usage says how to give one, and that a path with a `*` is quoted.
        #expect(CLIParser.usage.contains("--match-path <path>"))
        #expect(CLIParser.usage.contains("k:menuItemLocations/*/k:bundle/k:_0"))
        #expect(CLIParser.usage.contains("Quote it"))
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

    @Test func negativeNumberValue() throws {
        // A value that starts with a single dash is a value: only two dashes make a word an option.
        #expect(try invocation(["probe", "layout-move", "--distance", "-40"]).command
                == .probe(.layoutMove, options: ["distance": "-40"]))
        #expect(try invocation(["probe", "layout-move", "--distance", "-1.5", "--to", "-x"]).command
                == .probe(.layoutMove, options: ["distance": "-1.5", "to": "-x"]))
        #expect(try invocation(["probe", "layout-move", "--distance", "-40", "--json"]).json)
    }

    @Test func duplicateOptionIsAnError() {
        #expect(usageError(["probe", "inventory", "--bundle-id", "a", "--bundle-id", "b"])
                == "The option “--bundle-id” is given twice. Run “mantel help” for usage.")
        // The same value twice is no better, and a flag counts too.
        #expect(usageError(["probe", "inventory", "--hold", "5", "--hold", "5"])
                == "The option “--hold” is given twice. Run “mantel help” for usage.")
        #expect(usageError(["probe", "inventory", "--allow-any", "--allow-any"])
                == "The option “--allow-any” is given twice. Run “mantel help” for usage.")
        // `--json` is not an option of the probe, so it may be said twice.
        #expect(usageError(["probe", "inventory", "--json", "--json"]) == nil)
    }

    @Test func bareDoubleDashIsAnError() {
        #expect(usageError(["probe", "inventory", "--"])
                == "Unexpected “--”. Options look like “--key value”. Run “mantel help” for usage.")
        #expect(usageError(["probe", "inventory", "--bundle-id", "x", "--"])
                == "Unexpected “--”. Options look like “--key value”. Run “mantel help” for usage.")
        // A single dash is not an option either.
        #expect(usageError(["probe", "inventory", "-x", "y"])
                == "Unexpected “-x”. Options look like “--key value”. Run “mantel help” for usage.")
    }

    @Test func jsonNeverConsumedAsValue() throws {
        // `--json` asks for JSON wherever it stands, so it is never the value of the option before it.
        #expect(usageError(["probe", "inventory", "--bundle-id", "--json"])
                == "The option “--bundle-id” needs a value. Run “mantel help” for usage.")
        let parsed = try invocation(["probe", "inventory", "--bundle-id", "--json", "x"])
        #expect(parsed.command == .probe(.inventory, options: ["bundle-id": "x"]))
        #expect(parsed.json)
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
        for arguments in [["help"], ["--help"], ["-h"], ["--json", "help"], ["help", "--yes"]] {
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
                     "mantel show hidden|all|none", "mantel focus on|off|toggle", "mantel refresh", "mantel reset [--yes]", "mantel engine",
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
        ["show"],
        ["show", "everything"],
        ["focus", "maybe"],
        ["reset", "--now"],
        ["engine", "--all"],
    ]) func nonsenseIsAUsageError(arguments: [String]) {
        #expect(usageError(arguments) != nil, "\(arguments) is refused")
    }

    @Test func aMissingOptionValueNamesTheOption() throws {
        let message = try #require(usageError(["probe", "inventory", "--bundle-id"]))
        #expect(message.contains("--bundle-id"))
    }
}
