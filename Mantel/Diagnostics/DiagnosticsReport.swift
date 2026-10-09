import AppKit
import MKCommands
import MKCore
import MKMenuBar

/// One row of the Diagnostics pane: what it is (which decides the button it has, if it has one) and how it stands.
struct DiagnosticsRow: Identifiable {
    enum Kind: String {
        case accessibility, screenRecording, allowlist, layoutFile, approvalsFile, controlSocket, journal, logFile
    }

    let kind: Kind
    let check: DiagnosticsCheck

    var id: Kind { kind }
}

/// Reads where each part of Mantel stands, for the Diagnostics pane, "Copy diagnostics" and `mantel diagnostics`. It only
/// reads: nothing here changes anything, or asks for a permission.
@MainActor
enum DiagnosticsReport {
    static func rows(for coordinator: AppCoordinator) async -> [DiagnosticsRow] {
        [
            await accessibility(coordinator),
            await screenRecording(coordinator),
            allowlist(),
            await file(.menuBarLayout, kind: .layoutFile, title: "Layout file", coordinator),
            await file(.controlCenterApprovals, kind: .approvalsFile, title: "\"Allow in the Menu Bar\" file", coordinator),
            controlSocket(coordinator),
            await journal(coordinator),
            logFile(coordinator),
        ]
    }

    /// The home folder, as the report writes it out (`~`).
    static var homeFolder: String {
        FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false).trimmingTrailingSlash()
    }

    /// What "Copy diagnostics" copies.
    static func text(rows: [DiagnosticsRow], probes: [ProbeName: ProbeReport]) -> String {
        DiagnosticsText.render(checks: rows.map(\.check), probes: probes, home: homeFolder)
    }

    /// What `mantel diagnostics` answers, besides the build.
    static func json(for coordinator: AppCoordinator) async -> JSONValue {
        let rows = await rows(for: coordinator)
        return DiagnosticsText.json(checks: rows.map(\.check), probes: await coordinator.probes.latestReports(), home: homeFolder)
    }

    // MARK: The checks

    private static func accessibility(_ coordinator: AppCoordinator) async -> DiagnosticsRow {
        let granted = await coordinator.permissionChecker.state(of: .accessibility) == .granted
        return DiagnosticsRow(kind: .accessibility, check: DiagnosticsCheck(
            title: "Accessibility", status: granted ? .ok : .problem,
            detail: granted ? "Granted. Mantel can read the menu bar."
                : "Not granted. Mantel can't read the menu bar. Allow it in Settings › Permissions."))
    }

    private static func screenRecording(_ coordinator: AppCoordinator) async -> DiagnosticsRow {
        let granted = await coordinator.permissionChecker.state(of: .screenRecording) == .granted
        return DiagnosticsRow(kind: .screenRecording, check: DiagnosticsCheck(
            title: "Screen Recording", status: granted ? .ok : .warning,
            detail: granted ? "Granted. Mantel can take pictures of the menu bar items."
                : "Not granted. It is optional: without it, items are shown by their app's icon."))
    }

    private static func allowlist() -> DiagnosticsRow {
        let inspection = LiveAllowlist().inspect()
        if let problem = inspection.problem {
            return DiagnosticsRow(kind: .allowlist, check: DiagnosticsCheck(
                title: "Private allowlist", status: .problem, detail: "\(problem). Mantel won't use it."))
        }
        return DiagnosticsRow(kind: .allowlist, check: DiagnosticsCheck(
            title: "Private allowlist", status: .ok, detail: "Found, and its methods are the ones Mantel was written against."))
    }

    /// Whether the file is where macOS keeps it, and whether Mantel has been given it. (Looking for the file may not be
    /// allowed for an app that hasn't been given it: "not found" can also mean "not visible".)
    private static func file(_ kind: FileGrantKind, kind rowKind: DiagnosticsRow.Kind, title: String,
                             _ coordinator: AppCoordinator) async -> DiagnosticsRow {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = ExpectedFile.expected(kind, home: home).candidates.first ?? ""
        let located = FileManager.default.fileExists(atPath: path)
        let granted = await coordinator.grants.grant(for: kind) != nil
        let check: DiagnosticsCheck
        switch (located, granted) {
        case (true, true):
            check = DiagnosticsCheck(title: title, status: .ok, detail: "Found and granted. \(path)")
        case (true, false):
            check = DiagnosticsCheck(title: title, status: .warning,
                                     detail: "Found, but not granted. Choose it in Settings › Permissions. \(path)")
        case (false, true):
            check = DiagnosticsCheck(title: title, status: .warning, detail: "Granted, but not found now at \(path)")
        case (false, false):
            check = DiagnosticsCheck(title: title, status: .unknown, detail: "Not seen at \(path), and not granted")
        }
        return DiagnosticsRow(kind: rowKind, check: check)
    }

    private static func controlSocket(_ coordinator: AppCoordinator) -> DiagnosticsRow {
        let path = coordinator.paths.controlSocket.path(percentEncoded: false)
        let listening = coordinator.isControlSocketListening
        return DiagnosticsRow(kind: .controlSocket, check: DiagnosticsCheck(
            title: "Control socket", status: listening ? .ok : .problem,
            detail: listening ? "Listening at \(path)" : "Not listening, so the mantel tool can't reach Mantel. \(path)"))
    }

    private static func journal(_ coordinator: AppCoordinator) async -> DiagnosticsRow {
        let waiting = await coordinator.journal.records().count
        let detail = switch waiting {
        case 0: "No change is waiting to be put back."
        case 1: "1 change is waiting to be put back."
        case let count: "\(count) changes are waiting to be put back."
        }
        return DiagnosticsRow(kind: .journal, check: DiagnosticsCheck(title: "Journal", status: waiting == 0 ? .ok : .warning, detail: detail))
    }

    private static func logFile(_ coordinator: AppCoordinator) -> DiagnosticsRow {
        let url = logFileURL(coordinator)
        let exists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        return DiagnosticsRow(kind: .logFile, check: DiagnosticsCheck(
            title: "Log file", status: exists ? .ok : .unknown,
            detail: exists ? url.path(percentEncoded: false) : "No log written yet. \(url.path(percentEncoded: false))"))
    }

    static func logFileURL(_ coordinator: AppCoordinator) -> URL {
        FileLogSink(directory: coordinator.paths.logs).currentFileURL
    }
}

private extension String {
    func trimmingTrailingSlash() -> String {
        hasSuffix("/") && count > 1 ? String(dropLast()) : self
    }
}
