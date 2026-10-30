import MKCommands
import Testing

@Suite("Command-line parser", .timeLimit(.minutes(2)))
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
        #expect(parsed.confirmation == "Reset the menu bar? Mantel shows every icon, puts back its temporary changes, and restarts macOS's menu bar. The order of your icons stays. [y/N] ")
        #expect(try invocation(["reset", "--json"]).confirmation == parsed.confirmation)
        // Only a reset and a restore of the order ask.
        for arguments in [["ping"], ["icons"], ["icon", "show", "x"], ["bar", "toggle"], ["recapture"], ["version"], ["refresh"], ["engine"], ["show", "all"], ["focus", "off"], ["settings"], ["probe", "inventory"]] {
            #expect(try invocation(arguments).confirmation == nil, "\(arguments)")
        }
        #expect(usageError(["reset", "now"]) == "“reset” takes no arguments, but got “now”. Run “mantel help” for usage.")
    }

    @Test func yesWithOtherCommandsIsAnError() {
        let refused = "“--yes” only goes with “reset” and “layout restore”. Run “mantel help” for usage."
        for arguments in [["show", "hidden", "--yes"], ["ping", "--yes"], ["--yes", "engine"], ["refresh", "--yes"], ["focus", "on", "--yes"],
                          ["settings", "about", "--yes"], ["probe", "inventory", "--yes"], ["diagnostics", "--yes"],
                          ["icons", "--yes"], ["icon", "show", "Notes", "--yes"], ["bar", "open", "--yes"], ["recapture", "--yes"]] {
            #expect(usageError(arguments) == refused, "\(arguments)")
        }
        // A command that is wrong in its own right is told so first.
        #expect(usageError(["show", "--yes"]) == "“show” needs one of: hidden, all, none. Run “mantel help” for usage.")
        #expect(usageError(["bogus", "--yes"]) == "“bogus” isn't a command. Run “mantel help” for usage.")
    }

    @Test func iconsWithAndWithoutSection() throws {
        #expect(try invocation(["icons"]).command == .icons(nil))
        #expect(try invocation(["icons", "--json"]).json)
        #expect(try invocation(["--json", "icons"]).command == .icons(nil))
        #expect(try invocation(["icons", "--section", "shown"]).command == .icons(.shown))
        #expect(try invocation(["icons", "--section", "hidden"]).command == .icons(.hidden))
        #expect(try invocation(["icons", "--section", "always"]).command == .icons(.always))
        #expect(try invocation(["icons", "--section", "grouped", "--json"]).command == .icons(.grouped))
        let needs = "“--section” needs one of: shown, hidden, always, grouped. Run “mantel help” for usage."
        #expect(usageError(["icons", "--section"]) == needs)
        #expect(usageError(["icons", "--section", "all"]) == needs)
        #expect(usageError(["icons", "--section", "shown", "hidden"]) == needs)
        #expect(usageError(["icons", "shown"])
                == "“icons” takes only “--section” and then one of: shown, hidden, always, grouped. It got “shown”. Run “mantel help” for usage.")
    }

    @Test func iconShowAndClick() throws {
        #expect(try invocation(["icon", "show", "Notes"]).command == .icon(.show, query: "Notes", kind: .left))
        #expect(try invocation(["icon", "click", "Notes"]).command == .icon(.click, query: "Notes", kind: .left))
        // The name is one argument: the shell keeps a quoted name together.
        #expect(try invocation(["icon", "click", "Wi-Fi and more"]).command == .icon(.click, query: "Wi-Fi and more", kind: .left))
        #expect(try invocation(["icon", "show", "com.example.notes::main", "--json"]).json)
        let needs = "“icon” needs show or click, then an icon's ID or name. Run “mantel help” for usage."
        for arguments in [["icon"], ["icon", "show"], ["icon", "click"], ["icon", "press", "Notes"], ["icon", "show", "Wi-Fi", "and", "more"],
                          ["icon", "Notes"], ["icon", "show", " "]] {
            #expect(usageError(arguments) == needs, "\(arguments)")
        }
    }

    @Test func clickKinds() throws {
        #expect(try invocation(["icon", "click", "Notes", "--right"]).command == .icon(.click, query: "Notes", kind: .right))
        #expect(try invocation(["icon", "click", "Notes", "--option"]).command == .icon(.click, query: "Notes", kind: .option))
        // The flag can stand anywhere, as `--json` can.
        #expect(try invocation(["--right", "icon", "click", "Notes"]).command == .icon(.click, query: "Notes", kind: .right))
        #expect(try invocation(["icon", "--option", "click", "Notes", "--json"]).command == .icon(.click, query: "Notes", kind: .option))
    }

    @Test func rightAndOptionTogetherIsAnError() {
        let refused = "“--right” and “--option” only go with “icon click”, one of them. Run “mantel help” for usage."
        #expect(usageError(["icon", "click", "Notes", "--right", "--option"]) == refused)
        #expect(usageError(["icon", "click", "Notes", "--option", "--right"]) == refused)
    }

    @Test func kindOnlyWithClick() {
        let refused = "“--right” and “--option” only go with “icon click”, one of them. Run “mantel help” for usage."
        for arguments in [["icon", "show", "Notes", "--right"], ["icon", "show", "Notes", "--option"], ["icons", "--right"], ["ping", "--option"],
                          ["bar", "open", "--right"], ["show", "hidden", "--option"], ["recapture", "--right"]] {
            #expect(usageError(arguments) == refused, "\(arguments)")
        }
        // A command that is wrong in its own right is told so first.
        #expect(usageError(["icon", "--right"]) == "“icon” needs show or click, then an icon's ID or name. Run “mantel help” for usage.")
    }

    @Test func barChanges() throws {
        #expect(try invocation(["bar", "open"]).command == .bar(.open, all: false))
        #expect(try invocation(["bar", "close"]).command == .bar(.close, all: false))
        #expect(try invocation(["bar", "toggle"]).command == .bar(.toggle, all: false))
        #expect(try invocation(["bar", "open", "--all"]).command == .bar(.open, all: true))
        #expect(try invocation(["bar", "--all", "toggle", "--json"]).command == .bar(.toggle, all: true))
        let needs = "“bar” needs one of: open, close, toggle. Run “mantel help” for usage."
        for arguments in [["bar"], ["bar", "show"], ["bar", "open", "close"], ["bar", "--all"]] {
            #expect(usageError(arguments) == needs, "\(arguments)")
        }
    }

    @Test func allOnlyWithBar() {
        let refused = "“--all” only goes with “bar”. Run “mantel help” for usage."
        for arguments in [["show", "all", "--all"], ["icons", "--all"], ["icon", "show", "Notes", "--all"], ["ping", "--all"],
                          ["recapture", "--all"], ["layout", "restore", "--all"], ["reset", "--all", "--yes"]] {
            #expect(usageError(arguments) == refused, "\(arguments)")
        }
    }

    @Test func recaptureTakesNoArguments() throws {
        #expect(try invocation(["recapture"]).command == .recapture)
        #expect(try invocation(["recapture"]).confirmation == nil)
        #expect(usageError(["recapture", "now"]) == "“recapture” takes no arguments, but got “now”. Run “mantel help” for usage.")
    }

    @Test func layoutRestoreAsks() throws {
        let parsed = try invocation(["layout", "restore"])
        #expect(parsed.command == .restoreLayout)
        #expect(parsed.confirmation == "Put the menu bar icons back in the order they had before Mantel changed it? [y/N] ")
        #expect(parsed.confirmation == CLIConfirmation.layoutRestoreQuestion)
        #expect(try invocation(["layout", "restore", "--json"]).confirmation == parsed.confirmation)
        let needs = "“layout” needs “restore”. Run “mantel help” for usage."
        for arguments in [["layout"], ["layout", "undo"], ["layout", "restore", "now"], ["layout", "--yes"]] {
            #expect(usageError(arguments) == needs, "\(arguments)")
        }
    }

    @Test func layoutRestoreYes() throws {
        for arguments in [["layout", "restore", "--yes"], ["--yes", "layout", "restore"], ["layout", "--yes", "restore"]] {
            let parsed = try invocation(arguments)
            #expect(parsed.command == .restoreLayout)
            #expect(parsed.confirmation == nil, "\(arguments)")
        }
        #expect(try invocation(["layout", "restore", "--yes", "--json"]).json)
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

    @Test func theStepsOfLayoutOrderAreSwitches() throws {
        // The lines the platform check runs: a switch takes no value, so the option after it is read as an option.
        #expect(try invocation(["probe", "layout-order", "--visibility"]).command == .probe(.layoutOrder, options: ["visibility": "true"]))
        #expect(try invocation(["probe", "layout-order", "--relaunch-item", "--extra-count", "2"]).command
                == .probe(.layoutOrder, options: ["relaunch-item": "true", "extra-count": "2"]))
        for step in ["dots", "dots-keep", "dots-restore"] {
            #expect(try invocation(["probe", "layout-order", "--\(step)"]).command == .probe(.layoutOrder, options: [step: "true"]))
        }
        #expect(try invocation(["probe", "layout-order", "--runs", "3", "--item", "extra.1"]).command
                == .probe(.layoutOrder, options: ["runs": "3", "item": "extra.1"]))
        #expect(try invocation(["probe", "click-path", "--item", "extra.1", "--kind", "right", "--route", "post", "--runs", "3"]).command
                == .probe(.clickPath, options: ["item": "extra.1", "kind": "right", "route": "post", "runs": "3"]))
        #expect(try invocation(["probe", "click-path", "--allow-any", "--item", "system:wifi", "--kind", "left", "--route", "post"]).command
                == .probe(.clickPath, options: ["allow-any": "true", "item": "system:wifi", "kind": "left", "route": "post"]))
        #expect(usageError(["probe", "layout-order", "--dots", "--dots"])
                == "The option “--dots” is given twice. Run “mantel help” for usage.")
        // A value that is not a switch's still needs one.
        #expect(usageError(["probe", "layout-order", "--extra-count"]) == "The option “--extra-count” needs a value. Run “mantel help” for usage.")
        for word in ["click-path", "layout-order", "--dots-keep", "--dots-restore", "--relaunch-item", "--visibility"] {
            #expect(CLIParser.usage.contains(word), "usage mentions \(word)")
        }
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
                     "mantel show hidden|all|none", "mantel focus on|off|toggle", "mantel refresh", "mantel reset [--yes]", "mantel engine", "mantel icons", "mantel icon show", "mantel icon click",
                     "mantel bar open|close|toggle", "mantel recapture", "mantel layout restore [--yes]",
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
