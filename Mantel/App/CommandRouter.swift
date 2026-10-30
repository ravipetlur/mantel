import Foundation
import MKCommands
import MKCore
import MKMenuBar

/// What the menu bar does for the commands that reach it. The menu bar controller is the one that does.
@MainActor
protocol MenuBarCommanding: AnyObject {
    /// Shows that much of what is hidden, or hides it again. Returns when it is done: the plan applied and the icons looked for on the bar.
    func show(_ target: ShowTarget) async
    /// Turns Focus Mode on or off, or the other of the two. Returns whether it is on now.
    func focus(_ change: FocusChange) async -> Bool
    /// Reads the menu bar again and applies the plan again. Says whether it did: not while a reset is under way.
    func refresh() async -> RefreshOutcome
    /// Shows every icon, puts back what Mantel changed, restarts macOS's menu bar and hides again. Returns when it is done.
    func reset() async -> ResetOutcome
    /// Which way of hiding icons is in use, and why.
    func engine() async -> JSONValue
    /// The icons the menu bar has (one section's, or the groups', when asked), as objects of their ID, app, name, section, group and picture.
    func icons(_ filter: IconListFilter?) async -> JSONValue
    /// Shows one icon, or shows and clicks it. The words are resolved to one icon here; the answer is the click's outcome as soon as it is sent.
    func icon(_ command: IconCommand, query: String, kind: ClickKind) async -> CommandResult
    /// Opens or closes the second bar. Returns whether it is open now.
    func bar(_ change: BarChange, all: Bool) async -> Bool
    /// Takes the pictures of the icons again.
    func recapture() async -> CommandResult
    /// Puts the menu bar icons back in the order they had before Mantel changed it.
    func restoreLayout() async -> CommandResult
}

/// Does what a command asks, inside the app. Commands come over the control socket from Mantel's own tools, which the
/// socket server has already checked; its handler hops to the main actor and calls `handle`.
///
/// It is a type of its own so that whatever starts the control socket can have it without knowing what each command
/// does.
@MainActor
final class CommandRouter {
    private let openSettings: (SettingsPage?) -> Void
    private let diagnostics: () async -> JSONValue
    private let menuBar: () -> (any MenuBarCommanding)?

    /// - Parameters:
    ///   - openSettings: shows the Settings window at a page, or at the page it was last on when that is nil.
    ///   - diagnostics: the checks, as JSON.
    ///   - menuBar: what hides and reveals, once the launch has made it; nil before. (Commands arrive over the control socket, which
    ///     listens before the menu bar exists.)
    init(openSettings: @escaping (SettingsPage?) -> Void,
         diagnostics: @escaping () async -> JSONValue,
         menuBar: @escaping () -> (any MenuBarCommanding)?) {
        self.openSettings = openSettings
        self.diagnostics = diagnostics
        self.menuBar = menuBar
    }

    func handle(_ command: MantelCommand) async -> CommandResult {
        switch command {
        case .ping:
            return .ok(.string("pong"))
        case .version:
            return .ok(Self.buildInfo())
        case .openSettings(let page):
            openSettings(page)
            return .ok(.null)
        case .diagnostics:
            var report = await diagnostics()
            if case .object(var object) = report {
                object["build"] = Self.buildInfo()
                report = .object(object)
            }
            return .ok(report)
        case .reset:
            guard let menuBar = menuBar() else { return Self.starting }
            return await menuBar.reset().result
        case .show(let target):
            guard let menuBar = menuBar() else { return Self.starting }
            await menuBar.show(target)
            return .ok(.string(CommandAnswers.show(target)))
        case .focus(let change):
            guard let menuBar = menuBar() else { return Self.starting }
            return .ok(.string(CommandAnswers.focus(isOn: await menuBar.focus(change))))
        case .refresh:
            guard let menuBar = menuBar() else { return Self.starting }
            return await menuBar.refresh().result
        case .engine:
            guard let menuBar = menuBar() else { return Self.starting }
            return .ok(await menuBar.engine())
        case .icons(let filter):
            guard let menuBar = menuBar() else { return Self.starting }
            return .ok(await menuBar.icons(filter))
        case .icon(let command, let query, let kind):
            guard let menuBar = menuBar() else { return Self.starting }
            return await menuBar.icon(command, query: query, kind: kind)
        case .bar(let change, let all):
            guard let menuBar = menuBar() else { return Self.starting }
            return .ok(.string(CommandAnswers.bar(isOpen: await menuBar.bar(change, all: all))))
        case .recapture:
            guard let menuBar = menuBar() else { return Self.starting }
            return await menuBar.recapture()
        case .restoreLayout:
            guard let menuBar = menuBar() else { return Self.starting }
            return await menuBar.restoreLayout()
        }
    }

    /// The answer to a command that needs the menu bar before the launch has made it.
    private static let starting = CommandResult.failure(code: .unavailable, message: CommandAnswers.stillStarting)

    /// This build: the version and build number from Info.plist, and the macOS it runs on.
    private static func buildInfo() -> JSONValue {
        let info = Bundle.main.infoDictionary ?? [:]
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return .object([
            "version": .string(info["CFBundleShortVersionString"] as? String ?? "unknown"),
            "build": .string(info["CFBundleVersion"] as? String ?? "unknown"),
            "macOS": .string("\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"),
        ])
    }
}
