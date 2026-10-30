import AppKit
import MKCommands
import MKCore
import MKMenuBar

/// One row of the Diagnostics pane: what it is (which decides the button it has, if it has one) and how it stands.
struct DiagnosticsRow: Identifiable {
    enum Kind: String {
        case accessibility, screenRecording, allowlist, layoutFile, approvalsFile, controlSocket, journal, logFile
        /// The order of the menu bar, the pictures of its icons and the space between them.
        case layoutWriter, iconImages, iconSpacing
        /// The rows that come from what the menu bar session last said (`MenuBarModel`), not from a read of their own.
        case hidingMethod, menuBar
        /// An icon macOS doesn't tie to its app: a row for each such app.
        case unattachedIcon
        /// The menu bar was left stuck by a change of displays and restarting MenuBarAgent didn't put it right.
        case stuckBar
    }

    let kind: Kind
    let check: DiagnosticsCheck
    /// Which of the rows of one kind this is: the menu bar has a row for each thing that kept its read from being whole.
    var index = 0

    var id: String { "\(kind.rawValue)-\(index)" }
}

/// Reads where each part of Mantel stands, for the Diagnostics pane, "Copy diagnostics" and `mantel diagnostics`. It only
/// reads: nothing here changes anything, or asks for a permission.
@MainActor
enum DiagnosticsReport {
    static func rows(for coordinator: AppCoordinator) async -> [DiagnosticsRow] {
        // Asked once, for the two rows that say what Screen Recording is.
        let recording = await coordinator.permissionChecker.state(of: .screenRecording) == .granted
        var rows = [await accessibility(coordinator), screenRecording(granted: recording)]
        rows += await layoutRows(coordinator, screenRecording: recording)
        rows += [
            allowlist(),
            await file(.menuBarLayout, kind: .layoutFile, title: "Layout file", coordinator),
            await file(.controlCenterApprovals, kind: .approvalsFile, title: "“Allow in the Menu Bar” file", coordinator),
            controlSocket(coordinator),
            await journal(coordinator),
            logFile(coordinator),
        ]
        return rows
    }

    /// The rows that come from what the menu bar session last said: how icons are hidden, and how much of the menu bar was read. They are
    /// made from `state` as it is (the pane reads it from the menu bar model, so that they change when it does), and say that nothing is
    /// known yet while there is none.
    ///
    /// `forPane` is for the pane's own rows: a problem that Refresh puts right says so ("Try Refresh menu bar below."), as the button is
    /// under the checks. The copied report and `mantel diagnostics` have no button, and carry the message alone.
    /// `names` are what the pane calls the apps by; the report has none, and names them by their bundle ID.
    static func liveRows(state: MenuBarState?, forPane: Bool = false, names: [String: String] = [:]) -> [DiagnosticsRow] {
        let method = DiagnosticsRow(kind: .hidingMethod, check: HidingDiagnostics.hidingMethodCheck(state?.engine))
        let menuBar = HidingDiagnostics.menuBarChecks(state?.inventory, suggestingRefresh: forPane).enumerated().map { index, check in
            DiagnosticsRow(kind: .menuBar, check: check, index: index)
        }
        let unattached = HidingDiagnostics.unattachedIconChecks(state?.unattachedApps ?? [], engine: state?.engine, names: names,
                                                                suggestingRefresh: forPane).enumerated().map { index, check in
            DiagnosticsRow(kind: .unattachedIcon, check: check, index: index)
        }
        let stuck = HidingDiagnostics.stuckBarChecks(notRecovered: state?.stuckBarNotRecovered ?? false).map {
            DiagnosticsRow(kind: .stuckBar, check: $0)
        }
        return [method] + menuBar + stuck + unattached
    }

    /// Every row, in the order the pane and the report show them: the permission checks first, then what the menu bar says, then the files.
    static func merged(polled: [DiagnosticsRow], live: [DiagnosticsRow]) -> [DiagnosticsRow] {
        let permissions = polled.prefix { $0.kind == .accessibility || $0.kind == .screenRecording }
        return Array(permissions) + live + polled.dropFirst(permissions.count)
    }

    /// The home folder, as the report writes it out (`~`).
    static var homeFolder: String {
        FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false).trimmingTrailingSlash()
    }

    /// What "Copy diagnostics" copies: the rows, then what hiding changes and how each app answered (by bundle ID), then the probes.
    static func text(rows: [DiagnosticsRow], state: MenuBarState?, probes: [ProbeName: ProbeReport]) -> String {
        DiagnosticsText.render(checks: rows.map(\.check), blocks: HidingDiagnostics.blocks(engine: state?.engine, inventory: state?.inventory),
                               probes: probes, home: homeFolder)
    }

    /// What `mantel diagnostics` answers, besides the build.
    static func json(for coordinator: AppCoordinator) async -> JSONValue {
        let state = coordinator.menuBar?.model.state
        let rows = merged(polled: await rows(for: coordinator), live: liveRows(state: state))
        return DiagnosticsText.json(checks: rows.map(\.check),
                                    blocks: HidingDiagnostics.blocks(engine: state?.engine, inventory: state?.inventory),
                                    probes: await coordinator.probes.latestReports(), home: homeFolder)
    }

    // MARK: The checks

    private static func accessibility(_ coordinator: AppCoordinator) async -> DiagnosticsRow {
        let granted = await coordinator.permissionChecker.state(of: .accessibility) == .granted
        return DiagnosticsRow(kind: .accessibility, check: DiagnosticsCheck(
            title: "Device control and data access", status: granted ? .ok : .problem,
            detail: granted ? "Granted. Mantel can read the menu bar."
                : "Not granted. Mantel can't read the menu bar. Allow it in Settings › Permissions."))
    }

    private static func screenRecording(granted: Bool) -> DiagnosticsRow {
        DiagnosticsRow(kind: .screenRecording, check: DiagnosticsCheck(
            title: "Screen Recording", status: granted ? .ok : .warning,
            detail: granted ? "Granted. Mantel can take pictures of the menu bar items."
                : "Not granted. It is optional: without it, items are shown by their app's icon."))
    }

    /// "Menu bar layout", "Icon images" and "Icon spacing": what the layout writer last said, what has been captured, and the spacing keys.
    /// (Nothing in them names an app, so the copied report has them as they are.)
    private static func layoutRows(_ coordinator: AppCoordinator, screenRecording recording: Bool) async -> [DiagnosticsRow] {
        let menuBar = coordinator.menuBar
        let images = LayoutDiagnostics.imageSummary(captured: menuBar?.itemImages.capturedDates ?? [])
        let checks = LayoutDiagnostics.rows(
            layout: menuBar?.model.state?.layout, images: (images.count, images.last, recording),
            spacing: await coordinator.spacingWriter.current(), spacingWorks: IconSpacing.macOSApplies)
        let kinds: [DiagnosticsRow.Kind] = [.layoutWriter, .iconImages, .iconSpacing]
        return zip(kinds, checks).map { DiagnosticsRow(kind: $0, check: $1) }
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
        // A journal that couldn't be read is left as it is, and nothing is changed in the system until the person moves it away.
        guard await coordinator.journal.isUsable else {
            let path = coordinator.paths.journalFile.path(percentEncoded: false)
            return DiagnosticsRow(kind: .journal, check: DiagnosticsCheck(
                title: "Journal", status: .problem, detail: JournalError.unreadable(path: path).errorDescription ?? path))
        }
        let check = JournalSummary.check(untilQuit: await coordinator.journal.untilQuitRecords().count,
                                         kept: await coordinator.journal.keptRecords().count)
        return DiagnosticsRow(kind: .journal, check: check)
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
