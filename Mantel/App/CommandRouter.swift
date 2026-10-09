import Foundation
import MKCommands
import MKCore
import MKMenuBar

/// Does what a command asks, inside the app. Commands come over the control socket from Mantel's own tools, which the
/// socket server has already checked; its handler hops to the main actor and calls `handle`.
///
/// It is a type of its own so that whatever starts the control socket can have it without knowing what each command
/// does.
@MainActor
final class CommandRouter {
    private let openSettings: (SettingsPage?) -> Void
    private let runProbe: (ProbeName, [String: String]) async -> ProbeReport?
    private let diagnostics: () async -> JSONValue

    /// - Parameters:
    ///   - openSettings: shows the Settings window at a page, or at the page it was last on when that is nil.
    ///   - runProbe: runs a probe with its options and gives its report; nil when Mantel is quitting.
    ///   - diagnostics: the checks and the last report of every probe, as JSON.
    init(openSettings: @escaping (SettingsPage?) -> Void,
         runProbe: @escaping (ProbeName, [String: String]) async -> ProbeReport?,
         diagnostics: @escaping () async -> JSONValue) {
        self.openSettings = openSettings
        self.runProbe = runProbe
        self.diagnostics = diagnostics
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
        case .probe(let name, let options):
            // The report is the answer whatever came of the probe: its errors and what it did restore are in it.
            guard let report = await runProbe(name, options) else {
                return .failure(code: .unavailable, message: "Mantel is quitting.")
            }
            return .ok(report.json)
        }
    }

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
