import Foundation
import MKCore

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
    /// The question `mantel layout restore` asks.
    public static let layoutRestoreQuestion = "Put the menu bar icons back in the order they had before Mantel changed it? [y/N] "

    /// The question `mantel reset` asks.
    public static let resetQuestion = "Reset the menu bar? Mantel shows every icon, puts back its temporary changes, and restarts macOS's menu bar. The order of your icons stays. [y/N] "

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

private extension MantelCommand {
    var isBar: Bool {
        if case .bar = self { true } else { false }
    }
}

/// The grammar of the `mantel` tool.
public enum CLIParser {
    private static let jsonFlag = "--json"
    /// Agrees to the question of `reset` or `layout restore` before it is asked.
    private static let yesFlag = "--yes"
    private static let rightFlag = "--right"
    private static let optionFlag = "--option"
    private static let allFlag = "--all"
    private static let sectionFlag = "--section"
    private static let allowAnyFlag = "allow-any"
    /// The options that are switches, with no value after them: a word that follows one is the next option. (The steps of `layout-order`
    /// are switches too.)
    private static let switches: Set<String> = [allowAnyFlag, "save-baseline", "compare", "visibility", "relaunch-item", "dots", "dots-keep",
                                                "dots-restore"]

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
          mantel icons [--section shown|hidden|always|grouped]
                                               List the icons: their IDs, apps, sections and pictures.
          mantel icon show <id-or-name>        Show one icon for a while. Quote a name that has spaces.
          mantel icon click <id-or-name> [--right | --option]
                                               Show one icon and click it. macOS gives an icon an
                                               option click as a plain one.
          mantel bar open|close|toggle [--all]
                                               Open or close the second bar; --all puts every hidden icon in it.
          mantel recapture                     Take the pictures of the icons again.
          mantel layout restore [--yes]        Put the menu bar icons back in the order they had before Mantel
                                               changed it. It asks first; --yes says yes beforehand.
          mantel settings [\(pages)]
                                               Open Mantel's settings, at a page.
          mantel probe <name> [--key value]... [--allow-any] [--save-baseline] [--compare]
                                               Run a probe. By default a probe that changes something touches
                                               only Mantel's test item; --allow-any lets it touch any app.
                                               The probes that change something need "Enable platform test"
                                               on in Settings › Diagnostics.
          mantel probe click-path [--item one|two|extra.<n>] [--kind left|right|option] [--route press|post|showMenu] [--runs <n>]
                                               Click an icon that is concealed, by a route, and record what comes of it.
          mantel probe layout-order [--runs <n>] [--item one|extra.<n>] [--visibility] [--relaunch-item --extra-count <n>]
                      [--dots | --dots-keep | --dots-restore]
                                               Write the test item's places in macOS's order table, and put them back.
                                               --dots-keep leaves Mantel's dots where they were put until --dots-restore.
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
        let right = arguments.contains(rightFlag), option = arguments.contains(optionFlag), all = arguments.contains(allFlag)
        let flags: Set<String> = [jsonFlag, yesFlag, rightFlag, optionFlag, allFlag]
        let words = arguments.filter { !flags.contains($0) }

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
        case "icons": command = parseIcons(rest)
        case "icon": command = parseIcon(rest, kind: iconKind(right: right, option: option))
        case "bar": command = parseBar(rest, all: all)
        case "recapture": command = noArguments(.recapture, verb: verb, rest)
        case "layout": command = parseLayout(rest)
        default: command = .failure(error("“\(verb)” isn't a command."))
        }
        // The flags belong to one command each: it is a mistake anywhere else. (A command that wasn't understood says so first.)
        if case .success(let sent) = command {
            if right || option {
                guard case .icon(.click, _, _) = sent, !(right && option) else {
                    return .failure(error("“--right” and “--option” only go with “icon click”, one of them."))
                }
            }
            if all, !sent.isBar {
                return .failure(error("“--all” only goes with “bar”."))
            }
            // `--yes` is for the commands that ask, and so is a question: it is a mistake anywhere else.
            if yes, sent != .reset, sent != .restoreLayout {
                return .failure(error("“--yes” only goes with “reset” and “layout restore”."))
            }
        }
        return command.map { sent in
            let question: String? = switch sent {
            case .reset: yes ? nil : CLIConfirmation.resetQuestion
            case .restoreLayout: yes ? nil : CLIConfirmation.layoutRestoreQuestion
            default: nil
            }
            return CLIInvocation(command: sent, json: json, confirmation: question)
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

    private static func iconKind(right: Bool, option: Bool) -> ClickKind {
        right ? .right : option ? .option : .left
    }

    private static func parseIcons(_ rest: [String]) -> Result<MantelCommand, CLIUsageError> {
        let sections = IconListFilter.allCases.map(\.rawValue).joined(separator: ", ")
        guard let first = rest.first else { return .success(.icons(nil)) }
        guard first == sectionFlag else {
            return .failure(error("“icons” takes only “--section” and then one of: \(sections). It got “\(first)”."))
        }
        guard rest.count == 2, let filter = IconListFilter(rawValue: rest[1]) else {
            return .failure(error("“--section” needs one of: \(sections)."))
        }
        return .success(.icons(filter))
    }

    private static func parseIcon(_ rest: [String], kind: ClickKind) -> Result<MantelCommand, CLIUsageError> {
        guard rest.count == 2, let command = IconCommand(rawValue: rest[0]), !rest[1].trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure(error("“icon” needs show or click, then an icon's ID or name."))
        }
        return .success(.icon(command, query: rest[1], kind: kind))
    }

    private static func parseBar(_ rest: [String], all: Bool) -> Result<MantelCommand, CLIUsageError> {
        guard rest.count == 1, let change = BarChange(rawValue: rest[0]) else {
            return .failure(error("“bar” needs one of: \(BarChange.allCases.map(\.rawValue).joined(separator: ", "))."))
        }
        return .success(.bar(change, all: all))
    }

    private static func parseLayout(_ rest: [String]) -> Result<MantelCommand, CLIUsageError> {
        guard rest == ["restore"] else { return .failure(error("“layout” needs “restore”.")) }
        return .success(.restoreLayout)
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
