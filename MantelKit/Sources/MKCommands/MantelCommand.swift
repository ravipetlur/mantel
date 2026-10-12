import Foundation

/// The pages of Mantel's Settings window a command can open, in the order the window lists them.
public enum SettingsPage: String, Codable, Sendable, CaseIterable {
    case general, layout, hotkeys, permissions, advanced, diagnostics, about
}

/// The probes, which measure what macOS does. The raw values are how the command line spells them.
public enum ProbeName: String, Codable, Sendable, CaseIterable {
    case allowlistInfo = "allowlist-info", allowlistActivate = "allowlist-activate", inventory
    case approvalsRead = "approvals-read", approvalsToggle = "approvals-toggle"
    case layoutRead = "layout-read", layoutMove = "layout-move"
    case capture, clickReplay = "click-replay", overflow, screenShare = "screen-share", menuBarHeight = "menu-bar-height"
    case grantPersistence = "grant-persistence"
    case revealLatency = "reveal-latency", approvalsDecode = "approvals-decode", approvalsFlip = "approvals-flip"
    case notchCoordinates = "notch-coordinates"
}

/// How much of what is put away `mantel show` brings onto the bar.
public enum ShowTarget: String, Codable, Sendable, CaseIterable {
    /// The icons in Hidden.
    case hidden
    /// The icons in Hidden and in Always Hidden.
    case all
    /// Nothing: whatever is shown is hidden again. (The command line says `none`; the case isn't named that, as a case called `none`
    /// is taken for `nil` where a `ShowTarget?` is.)
    case nothing = "none"
}

/// What `mantel focus` does to Focus Mode.
public enum FocusChange: String, Codable, Sendable, CaseIterable {
    case on, off, toggle
}

/// What the `mantel` tool can ask the running app to do.
///
/// On the wire a command is one JSON object named by its `command` key, with its arguments beside it:
/// `{"command":"ping"}`, `{"command":"openSettings","page":"general"}`, `{"command":"show","target":"hidden"}`,
/// `{"command":"focus","change":"toggle"}`, `{"command":"probe","name":"inventory","options":{"allow-any":"true"}}`.
public enum MantelCommand: Codable, Sendable, Equatable {
    case ping
    case version
    case openSettings(SettingsPage?)
    case diagnostics
    case probe(ProbeName, options: [String: String])
    /// Shows that much of what is hidden, or hides it again.
    case show(ShowTarget)
    case focus(FocusChange)
    /// Reads the menu bar again and applies the sections again.
    case refresh
    /// Shows every icon, puts back what Mantel changed and restarts macOS's menu bar.
    case reset
    /// Says which way of hiding icons is in use, and why.
    case engine

    /// What the log says of a command: its name, and a probe's name. Never the options, which are the caller's words.
    public var name: String {
        switch self {
        case .ping: "ping"
        case .version: "version"
        case .openSettings: "settings"
        case .diagnostics: "diagnostics"
        case .probe(let probe, _): "probe \(probe.rawValue)"
        case .show: "show"
        case .focus: "focus"
        case .refresh: "refresh"
        case .reset: "reset"
        case .engine: "engine"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case command, page, name, options, target, change
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .command) {
        case "ping":
            self = .ping
        case "version":
            self = .version
        case "diagnostics":
            self = .diagnostics
        case "openSettings":
            self = .openSettings(try container.decodeIfPresent(SettingsPage.self, forKey: .page))
        case "probe":
            self = .probe(try container.decode(ProbeName.self, forKey: .name),
                          options: try container.decodeIfPresent([String: String].self, forKey: .options) ?? [:])
        case "show":
            self = .show(try container.decode(ShowTarget.self, forKey: .target))
        case "focus":
            self = .focus(try container.decode(FocusChange.self, forKey: .change))
        case "refresh":
            self = .refresh
        case "reset":
            self = .reset
        case "engine":
            self = .engine
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .command, in: container,
                                                   debugDescription: "Unknown command \"\(other)\"")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ping:
            try container.encode("ping", forKey: .command)
        case .version:
            try container.encode("version", forKey: .command)
        case .diagnostics:
            try container.encode("diagnostics", forKey: .command)
        case .openSettings(let page):
            try container.encode("openSettings", forKey: .command)
            try container.encodeIfPresent(page, forKey: .page)
        case .probe(let probe, let options):
            try container.encode("probe", forKey: .command)
            try container.encode(probe, forKey: .name)
            try container.encode(options, forKey: .options)
        case .show(let target):
            try container.encode("show", forKey: .command)
            try container.encode(target, forKey: .target)
        case .focus(let change):
            try container.encode("focus", forKey: .command)
            try container.encode(change, forKey: .change)
        case .refresh:
            try container.encode("refresh", forKey: .command)
        case .reset:
            try container.encode("reset", forKey: .command)
        case .engine:
            try container.encode("engine", forKey: .command)
        }
    }
}

/// Why a command failed. `rejected` is the app refusing the client; the rest are about the request or the work.
public enum CommandErrorCode: String, Codable, Sendable {
    case badRequest, rejected, unavailable, failed, unknownCommand
}

/// What a command comes to: a value, or a failure that says what happened and what to do.
///
/// On the wire: `{"status":"ok","value":…}` or `{"status":"failure","code":"failed","message":"…"}`.
public enum CommandResult: Codable, Sendable, Equatable {
    case ok(JSONValue)
    case failure(code: CommandErrorCode, message: String)

    private enum CodingKeys: String, CodingKey {
        case status, value, code, message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "ok":
            self = .ok(try container.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null)
        case "failure":
            self = .failure(code: try container.decode(CommandErrorCode.self, forKey: .code),
                            message: try container.decode(String.self, forKey: .message))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .status, in: container,
                                                   debugDescription: "Unknown status \"\(other)\"")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok(let value):
            try container.encode("ok", forKey: .status)
            try container.encode(value, forKey: .value)
        case .failure(let code, let message):
            try container.encode("failure", forKey: .status)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
        }
    }
}
