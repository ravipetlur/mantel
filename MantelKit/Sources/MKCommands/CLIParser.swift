import Foundation

/// What the person typed, understood: the command to send, and whether they want the answer as JSON.
public struct CLIInvocation: Sendable, Equatable {
    public let command: MantelCommand
    public let json: Bool
    /// The question to ask before the command is sent, when it is one that has to be agreed to (`reset` without `--yes`). The tool
    /// prints it, reads a line, and sends the command only if `CLIConfirmation.accepts` the answer. Nil for every other command.
    public let confirmation: String?

    public init(command: MantelCommand, json: Bool, confirmation: String? = nil) {
        self.command = command
        self.json = json
        self.confirmation = confirmation
    }
}

/// What counts as agreeing to a question the tool asks.
public enum CLIConfirmation {
    /// The question `mantel reset` asks.
    public static let resetQuestion = "Reset the menu bar? Mantel shows every icon, puts back what it changed, and restarts macOS's menu bar. [y/N] "

    /// Whether the answer, a line the person typed (nil at the end of the input), is a yes: `y` or `yes`, in any case, with whatever
    /// blanks are around it. Anything else, an empty line included, is a no.
    public static func accepts(_ answer: String?) -> Bool {
        guard let answer else { return false }
        let word = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return word == "y" || word == "yes"
    }
}

/// Why the arguments weren't understood, in words that say what to type instead.
public struct CLIUsageError: Error, Sendable, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// The grammar of the `mantel` tool.
public enum CLIParser {
    private static let jsonFlag = "--json"
    /// Agrees to the question of `reset` before it is asked.
    private static let yesFlag = "--yes"
    private static let allowAnyFlag = "allow-any"
    /// The options that are switches, with no value after them: a word that follows one is the next option.
    private static let switches: Set<String> = [allowAnyFlag, "save-baseline", "compare"]

    public static let usage: String = {
        let pages = SettingsPage.allCases.map(\.rawValue).joined(separator: "|")
        let probes = ProbeName.allCases.map { "  \($0.rawValue)" }.joined(separator: "\n")
        return """
        Usage:
          mantel ping                          Check that Mantel is running.
          mantel version                       Print Mantel's version.
          mantel diagnostics                   Print what Mantel knows about itself.
          mantel show hidden|all|none          Show the hidden icons, all of them, or hide them again.
          mantel focus on|off|toggle           Turn Focus Mode on or off.
          mantel refresh                       Read the menu bar again and apply the sections again.
          mantel reset [--yes]                 Show every icon, put back what Mantel changed and restart macOS's
                                               menu bar. It asks first; --yes says yes beforehand.
          mantel engine                        Print which way of hiding icons is in use, and why.
          mantel settings [\(pages)]
                                               Open Mantel's settings, at a page.
          mantel probe <name> [--key value]... [--allow-any] [--save-baseline] [--compare]
                                               Run a probe. By default a probe that changes something touches
                                               only Mantel's test item; --allow-any lets it touch any app.
                                               The probes that change something need "Enable platform test"
                                               on in Settings › Diagnostics.
          mantel probe approvals-flip --flag-path <path> --codec nested|flip [--runs <n>]
                      [--id-key <key> | --match-path <path>]
                                               Flip the test item's switch in the approvals list, and put it back.
                                               A path is steps like k:name, i:2 and m:key=value, joined by /.
                                               --match-path finds the entry by the way to its bundle ID, with * for
                                               any element (k:menuItemLocations/*/k:bundle/k:_0). Quote it: the
                                               shell takes * for a file name. --flag-path is then from that entry
                                               (k:isAllowed).
          mantel help                          Print this.

        Add --json anywhere to print the answer as JSON.

        Probes:
        \(probes)

        Exit codes: 0 done, 1 Mantel said it couldn't, 2 wrong arguments, 3 Mantel isn't running, 4 Mantel refused this tool.
        """
    }()

    /// True when the person asked for help: `help`, `--help` or `-h` as the first word. Help isn't a command to send, so
    /// `parse` has no result for it; the tool prints `usage` and succeeds.
    public static func isHelpRequest(_ arguments: [String]) -> Bool {
        guard let first = arguments.filter({ $0 != jsonFlag && $0 != yesFlag }).first else { return false }
        return ["help", "--help", "-h"].contains(first)
    }

    /// Reads the arguments after the tool's name. No arguments, and a request for help, come back as `usage` itself.
    public static func parse(_ arguments: [String]) -> Result<CLIInvocation, CLIUsageError> {
        let json = arguments.contains(jsonFlag)
        let yes = arguments.contains(yesFlag)
        let words = arguments.filter { $0 != jsonFlag && $0 != yesFlag }

        guard let verb = words.first, !isHelpRequest(words) else {
            return .failure(CLIUsageError(message: usage))
        }
        let rest = Array(words.dropFirst())

        let command: Result<MantelCommand, CLIUsageError>
        switch verb {
        case "ping": command = noArguments(.ping, verb: verb, rest)
        case "version": command = noArguments(.version, verb: verb, rest)
        case "diagnostics": command = noArguments(.diagnostics, verb: verb, rest)
        case "settings": command = parseSettings(rest)
        case "probe": command = parseProbe(rest)
        case "show": command = parseShow(rest)
        case "focus": command = parseFocus(rest)
        case "refresh": command = noArguments(.refresh, verb: verb, rest)
        case "reset": command = noArguments(.reset, verb: verb, rest)
        case "engine": command = noArguments(.engine, verb: verb, rest)
        default: command = .failure(error("“\(verb)” isn't a command."))
        }
        // `--yes` is for the one command that asks: it is a mistake anywhere else, and so is a question for a command that never asks.
        if yes, case .success(let sent) = command, sent != .reset {
            return .failure(error("“--yes” only goes with “reset”."))
        }
        return command.map { sent in
            CLIInvocation(command: sent, json: json, confirmation: sent == .reset && !yes ? CLIConfirmation.resetQuestion : nil)
        }
    }

    // MARK: Commands

    private static func noArguments(_ command: MantelCommand, verb: String,
                                    _ rest: [String]) -> Result<MantelCommand, CLIUsageError> {
        if let extra = rest.first {
            return .failure(error("“\(verb)” takes no arguments, but got “\(extra)”."))
        }
        return .success(command)
    }

    private static func parseSettings(_ rest: [String]) -> Result<MantelCommand, CLIUsageError> {
        guard let word = rest.first else { return .success(.openSettings(nil)) }
        if rest.count > 1 {
            return .failure(error("“settings” takes one page, but got “\(rest[1])” after “\(word)”."))
        }
        guard let page = SettingsPage(rawValue: word) else {
            return .failure(error("“\(word)” isn't a settings page. The pages are: \(pageNames)."))
        }
        return .success(.openSettings(page))
    }

    private static func parseShow(_ rest: [String]) -> Result<MantelCommand, CLIUsageError> {
        guard rest.count == 1, let target = ShowTarget(rawValue: rest[0]) else {
            return .failure(error("“show” needs one of: \(ShowTarget.allCases.map(\.rawValue).joined(separator: ", "))."))
        }
        return .success(.show(target))
    }

    private static func parseFocus(_ rest: [String]) -> Result<MantelCommand, CLIUsageError> {
        guard rest.count == 1, let change = FocusChange(rawValue: rest[0]) else {
            return .failure(error("“focus” needs one of: \(FocusChange.allCases.map(\.rawValue).joined(separator: ", "))."))
        }
        return .success(.focus(change))
    }

    private static func parseProbe(_ rest: [String]) -> Result<MantelCommand, CLIUsageError> {
        guard let word = rest.first, !word.hasPrefix("-") else {
            return .failure(error("“probe” needs a name. The probes are: \(probeNames)."))
        }
        guard let name = ProbeName(rawValue: word) else {
            return .failure(error("“\(word)” isn't a probe. The probes are: \(probeNames)."))
        }

        var options: [String: String] = [:]
        var index = 1
        while index < rest.count {
            let token = rest[index]
            guard token.hasPrefix("--"), token.count > 2 else {
                return .failure(error("Unexpected “\(token)”. Options look like “--key value”."))
            }
            let key = String(token.dropFirst(2))
            guard options[key] == nil else {
                return .failure(error("The option “\(token)” is given twice."))
            }
            if switches.contains(key) {
                options[key] = "true"
                index += 1
                continue
            }
            // A value may start with a single dash (`--distance -40`); a word that starts with two is the next option.
            guard index + 1 < rest.count, !rest[index + 1].hasPrefix("--") else {
                return .failure(error("The option “\(token)” needs a value."))
            }
            options[key] = rest[index + 1]
            index += 2
        }
        return .success(.probe(name, options: options))
    }

    // MARK: Messages

    private static var pageNames: String {
        SettingsPage.allCases.map(\.rawValue).joined(separator: ", ")
    }

    private static var probeNames: String {
        ProbeName.allCases.map(\.rawValue).joined(separator: ", ")
    }

    private static func error(_ problem: String) -> CLIUsageError {
        CLIUsageError(message: "\(problem) Run “mantel help” for usage.")
    }
}
