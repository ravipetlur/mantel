import Foundation
import MKCore

/// The pages of Mantel's Settings window, in the order the window's sidebar lists them. The one list of them: the window draws its sidebar
/// from it and a command names a page by its raw value, and each page needs a pane of its own in the app before the app builds.
public enum SettingsPage: String, Codable, Sendable, CaseIterable {
    case general, layout, secondBar = "second-bar", hotkeys, cosmetics, permissions, advanced, diagnostics, about

    /// What the sidebar and the window's title call the page.
    public var title: String {
        switch self {
        case .general: "General"
        case .layout: "Layout"
        case .secondBar: "Second bar"
        case .hotkeys: "Hotkeys"
        case .cosmetics: "Cosmetics"
        case .permissions: "Permissions"
        case .advanced: "Advanced"
        case .diagnostics: "Diagnostics"
        case .about: "About"
        }
    }

    /// The SF Symbol the sidebar shows beside the title.
    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .layout: "rectangle.split.3x1"
        case .secondBar: "menubar.dock.rectangle"
        case .hotkeys: "keyboard"
        case .cosmetics: "paintpalette"
        case .permissions: "lock.shield"
        case .advanced: "slider.horizontal.3"
        case .diagnostics: "stethoscope"
        case .about: "info.circle"
        }
    }
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
    /// What a click on an icon that is concealed does: where it shows up, whether a press or a posted click opens its menu, and what
    /// the item received.
    case clickPath = "click-path"
    /// Pictures of the icons on each bar, with what is learned making them.
    case iconCapture = "icon-capture"
    /// How the order table's distances relate to where the icons are.
    case layoutMap = "layout-map"
    /// Whether writing the order table re-sorts the menu bar, how fast, and what else it does to the icons.
    case layoutOrder = "layout-order"
    /// Whether the icon spacing preferences change how wide icons are.
    case spacing
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

/// Which of the icons `mantel icons` lists. `grouped` is the ones in a group.
public enum IconListFilter: String, Codable, Sendable, CaseIterable {
    case shown, hidden, always, grouped
}

/// What `mantel icon` does to one icon: shows it, or shows it and clicks it.
public enum IconCommand: String, Codable, Sendable {
    case show, click
}

/// What `mantel bar` does to the second bar.
public enum BarChange: String, Codable, Sendable, CaseIterable {
    case open, close, toggle
}

/// What the `mantel` tool can ask the running app to do.
///
/// On the wire a command is one JSON object named by its `command` key, with its arguments beside it:
/// `{"command":"ping"}`, `{"command":"openSettings","page":"general"}`, `{"command":"show","target":"hidden"}`,
/// `{"command":"focus","change":"toggle"}`, `{"command":"probe","name":"inventory","options":{"allow-any":"true"}}`,
/// `{"command":"icon","action":"click","query":"Notes","kind":"right"}`, `{"command":"bar","change":"open","all":true}`.
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
    /// Lists the icons the menu bar has, all of them or one section's (or the groups').
    case icons(IconListFilter?)
    /// Shows one icon, or shows it and clicks it. `query` is the person's words: an icon's ID, or part of its name.
    case icon(IconCommand, query: String, kind: ClickKind)
    /// Opens or closes the second bar, with everything that is put away in it (`all`) or what is in Hidden.
    case bar(BarChange, all: Bool)
    /// Takes the pictures of the icons again.
    case recapture
    /// Puts the menu bar's icons back in the order they had before Mantel changed it.
    case restoreLayout

    /// What the log says of a command: its name, and a probe's name. Never the options, which are the caller's words, and never an icon's
    /// words (`icon show` and `icon click` are all that is said).
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
        case .icons: "icons"
        case .icon(let command, _, _): "icon \(command.rawValue)"
        case .bar: "bar"
        case .recapture: "recapture"
        case .restoreLayout: "layout restore"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case command, page, name, options, target, change, filter, action, query, kind, all
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
        case "icons":
            self = .icons(try container.decodeIfPresent(IconListFilter.self, forKey: .filter))
        case "icon":
            self = .icon(try container.decode(IconCommand.self, forKey: .action), query: try container.decode(String.self, forKey: .query),
                         kind: try container.decodeIfPresent(ClickKind.self, forKey: .kind) ?? .left)
        case "bar":
            self = .bar(try container.decode(BarChange.self, forKey: .change), all: try container.decodeIfPresent(Bool.self, forKey: .all) ?? false)
        case "recapture":
            self = .recapture
        case "restoreLayout":
            self = .restoreLayout
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
        case .icons(let filter):
            try container.encode("icons", forKey: .command)
            try container.encodeIfPresent(filter, forKey: .filter)
        case .icon(let command, let query, let kind):
            try container.encode("icon", forKey: .command)
            try container.encode(command, forKey: .action)
            try container.encode(query, forKey: .query)
            try container.encode(kind, forKey: .kind)
        case .bar(let change, let all):
            try container.encode("bar", forKey: .command)
            try container.encode(change, forKey: .change)
            try container.encode(all, forKey: .all)
        case .recapture:
            try container.encode("recapture", forKey: .command)
        case .restoreLayout:
            try container.encode("restoreLayout", forKey: .command)
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
