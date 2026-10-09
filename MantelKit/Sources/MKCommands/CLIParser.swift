import Foundation

/// What the person typed, understood: the command to send, and whether they want the answer as JSON.
public struct CLIInvocation: Sendable, Equatable {
    public let command: MantelCommand
    public let json: Bool

    public init(command: MantelCommand, json: Bool) {
        self.command = command
        self.json = json
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
    private static let allowAnyFlag = "allow-any"

    public static let usage: String = {
        let pages = SettingsPage.allCases.map(\.rawValue).joined(separator: "|")
        let probes = ProbeName.allCases.map { "  \($0.rawValue)" }.joined(separator: "\n")
        return """
        Usage:
          mantel ping                          Check that Mantel is running.
          mantel version                       Print Mantel's version.
          mantel diagnostics                   Print what Mantel knows about itself.
          mantel settings [\(pages)]
                                               Open Mantel's settings, at a page.
          mantel probe <name> [--key value]... [--allow-any]
                                               Run a probe. By default a probe that changes something touches
                                               only Mantel's test item; --allow-any lets it touch any app.
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
        guard let first = arguments.filter({ $0 != jsonFlag }).first else { return false }
        return ["help", "--help", "-h"].contains(first)
    }

    /// Reads the arguments after the tool's name. No arguments, and a request for help, come back as `usage` itself.
    public static func parse(_ arguments: [String]) -> Result<CLIInvocation, CLIUsageError> {
        let json = arguments.contains(jsonFlag)
        let words = arguments.filter { $0 != jsonFlag }

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
        default: command = .failure(error("\"\(verb)\" isn't a command."))
        }
        return command.map { CLIInvocation(command: $0, json: json) }
    }

    // MARK: Commands

    private static func noArguments(_ command: MantelCommand, verb: String,
                                    _ rest: [String]) -> Result<MantelCommand, CLIUsageError> {
        if let extra = rest.first {
            return .failure(error("\"\(verb)\" takes no arguments, but got \"\(extra)\"."))
        }
        return .success(command)
    }

    private static func parseSettings(_ rest: [String]) -> Result<MantelCommand, CLIUsageError> {
        guard let word = rest.first else { return .success(.openSettings(nil)) }
        if rest.count > 1 {
            return .failure(error("\"settings\" takes one page, but got \"\(rest[1])\" after \"\(word)\"."))
        }
        guard let page = SettingsPage(rawValue: word) else {
            return .failure(error("\"\(word)\" isn't a settings page. The pages are: \(pageNames)."))
        }
        return .success(.openSettings(page))
    }

    private static func parseProbe(_ rest: [String]) -> Result<MantelCommand, CLIUsageError> {
        guard let word = rest.first, !word.hasPrefix("-") else {
            return .failure(error("\"probe\" needs a name. The probes are: \(probeNames)."))
        }
        guard let name = ProbeName(rawValue: word) else {
            return .failure(error("\"\(word)\" isn't a probe. The probes are: \(probeNames)."))
        }

        var options: [String: String] = [:]
        var index = 1
        while index < rest.count {
            let token = rest[index]
            guard token.hasPrefix("--"), token.count > 2 else {
                return .failure(error("Unexpected \"\(token)\". Options look like \"--key value\"."))
            }
            let key = String(token.dropFirst(2))
            if key == allowAnyFlag {
                options[key] = "true"
                index += 1
                continue
            }
            guard index + 1 < rest.count, !rest[index + 1].hasPrefix("--") else {
                return .failure(error("The option \"\(token)\" needs a value."))
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
        CLIUsageError(message: "\(problem) Run \"mantel help\" for usage.")
    }
}
