import Foundation

/// The pages of Mantel's Settings window a command can open.
public enum SettingsPage: String, Codable, Sendable, CaseIterable {
    case general, hotkeys, permissions, diagnostics, about
}

/// The probes, which measure what macOS does. The raw values are how the command line spells them.
public enum ProbeName: String, Codable, Sendable, CaseIterable {
    case allowlistInfo = "allowlist-info", allowlistActivate = "allowlist-activate", inventory
    case approvalsRead = "approvals-read", approvalsToggle = "approvals-toggle"
    case layoutRead = "layout-read", layoutMove = "layout-move"
    case capture, clickReplay = "click-replay", overflow, screenShare = "screen-share", menuBarHeight = "menu-bar-height"
    case grantPersistence = "grant-persistence"
}

/// What the `mantel` tool can ask the running app to do.
///
/// On the wire a command is one JSON object named by its `command` key, with its arguments beside it:
/// `{"command":"ping"}`, `{"command":"openSettings","page":"general"}`,
/// `{"command":"probe","name":"inventory","options":{"allow-any":"true"}}`.
public enum MantelCommand: Codable, Sendable, Equatable {
    case ping
    case version
    case openSettings(SettingsPage?)
    case diagnostics
    case probe(ProbeName, options: [String: String])

    /// What the log says of a command: its name, and a probe's name. Never the options, which are the caller's words.
    public var name: String {
        switch self {
        case .ping: "ping"
        case .version: "version"
        case .openSettings: "settings"
        case .diagnostics: "diagnostics"
        case .probe(let probe, _): "probe \(probe.rawValue)"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case command, page, name, options
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
