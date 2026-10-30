import AppKit
import MKCommands
import MKCore
import MKLayout
import MKMenuBar
import SwiftUI

/// What the Diagnostics pane shows and does. Nothing in it is saved.
@MainActor
@Observable
final class DiagnosticsModel {
    private let coordinator: AppCoordinator

    private(set) var rows: [DiagnosticsRow] = []
    /// What the last button said happened: "Copied", or how the replay ended.
    private(set) var message: String?
    private(set) var isReplaying = false
    /// A refresh or a reset of the menu bar is under way (the buttons wait), and what the last one said.
    private(set) var menuBarBusy = false
    private var isConfirmingReset = false
    private(set) var menuBarMessage: String?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        identities = AppIdentities(runningApps: coordinator.runningApps)
    }

    /// What the menu bar session last said, from the model the menu bar controller keeps: nil until it has read the menu bar. The pane
    /// reads it while it draws, so that what is drawn from it changes when it does, with nothing polling for it.
    var menuBarState: MenuBarState? {
        coordinator.menuBar?.model.state
    }

    /// Every row of Checks as the pane shows it: the ones read for the pane, and the ones the menu bar's state makes (a problem Refresh
    /// puts right says to try the button under the checks).
    var allRows: [DiagnosticsRow] {
        let names = (menuBarState?.unattachedApps ?? []).reduce(into: [String: String]()) { $0[$1] = identities.name(for: $1) }
        return DiagnosticsReport.merged(polled: rows, live: DiagnosticsReport.liveRows(state: menuBarState, forPane: true, names: names))
    }

    /// The same rows as the copied report has them: the messages alone, as there is no button below.
    var reportRows: [DiagnosticsRow] {
        DiagnosticsReport.merged(polled: rows, live: DiagnosticsReport.liveRows(state: menuBarState))
    }

    /// How each way of hiding stands, one line each.
    var engineLines: [String] {
        HidingDiagnostics.engineLines(menuBarState?.engine)
    }

    /// How each app answered when the menu bar was read, by the name the pane knows it by.
    var reachRows: [ReachRow] {
        let inventory = menuBarState?.inventory
        let names = (inventory?.reach ?? []).reduce(into: [String: String]()) { $0[$1.bundleID] = identities.name(for: $1.bundleID) }
        return HidingDiagnostics.reachRows(inventory, names: names)
    }

    private let identities: AppIdentities

    func refresh() async {
        let fresh = await DiagnosticsReport.rows(for: coordinator)
        // Set only when something changed, so that the pane isn't redrawn every two seconds for nothing.
        if fresh.map(\.check) != rows.map(\.check) { rows = fresh }
    }

    func replayNow() async {
        guard !isReplaying else { return }
        // Set before anything is awaited: a second click that comes while the decision is being made finds it set, and does
        // nothing, so two replays never run.
        isReplaying = true
        // Putting back what a hiding method is using would undo it from under it: the reason is the message.
        let decision = await ReplayNowPolicy.decide(journalEmpty: coordinator.journalIsEmpty,
                                                    engineHoldsJournal: coordinator.engineHoldsJournal)
        if case .refused(let reason) = decision {
            message = reason
            isReplaying = false
            return
        }
        message = await coordinator.replayJournalNow()
        isReplaying = false
        // What the replay put back may have been what kept a way of hiding from being used.
        coordinator.permissionsChanged()
        await refresh()
    }

    /// "Refresh menu bar": starts over from what is true, as the dots' menu and `mantel refresh` do.
    func refreshMenuBar() async {
        guard !menuBarBusy else { return }
        menuBarBusy = true
        menuBarMessage = nil
        if let menuBar = coordinator.menuBar {
            // Not while a reset is under way: it says so, and doesn't say that it refreshed.
            menuBarMessage = await menuBar.refresh().message
        } else {
            menuBarMessage = CommandAnswers.stillStarting
        }
        menuBarBusy = false
        await refresh()
    }

    /// "Reset menu bar…": asks first, then does what `mantel reset` does. (There is no menu item for it: it is here and on the command line.)
    func resetMenuBar() async {
        guard !menuBarBusy, !isConfirmingReset else { return }
        // The alert starts on the run loop's next turn, so a second click can come before it is up: it is refused, not queued behind it.
        isConfirmingReset = true
        let confirmed = await confirmReset()
        isConfirmingReset = false
        guard confirmed, !menuBarBusy else { return }
        menuBarBusy = true
        menuBarMessage = nil
        // A reset that couldn't start (the menu bar isn't made yet) changed nothing, so it is refused, not failed.
        let outcome = await coordinator.menuBar?.reset() ?? .refused(CommandAnswers.stillStarting)
        menuBarMessage = outcome.message
        menuBarBusy = false
        await refresh()
    }

    private func confirmReset() async -> Bool {
        let alert = NSAlert()
        alert.messageText = ResetCopy.alertTitle
        alert.informativeText = ResetCopy.alertText
        alert.addButton(withTitle: ResetCopy.confirmButton)
        alert.addButton(withTitle: ResetCopy.cancelButton)
        return await ModalLoop.run(alert) == .alertFirstButtonReturn
    }

    func copy() async {
        await refresh()
        let text = DiagnosticsReport.text(rows: reportRows, state: menuBarState)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = "Copied."
    }

    func showLog() {
        let url = DiagnosticsReport.logFileURL(coordinator)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

/// The checks, the engine status, and "Copy diagnostics".
struct DiagnosticsPane: View {
    @State private var model: DiagnosticsModel

    init(coordinator: AppCoordinator) {
        _model = State(initialValue: DiagnosticsModel(coordinator: coordinator))
    }

    var body: some View {
        Form {
            Section {
                ForEach(model.allRows) { row in
                    CheckRow(row: row, model: model)
                }
            } header: {
                Text("Checks")
            } footer: {
                menuBarControls
            }
            Section("Ways of hiding") {
                ForEach(model.engineLines, id: \.self) { line in
                    Text(line).textSelection(.enabled)
                }
            }
            Section("What hiding changes") {
                ForEach(HidingDiagnostics.whatHidingChanges, id: \.self) { line in
                    Text(line).foregroundStyle(.secondary)
                }
            }
            Section("How apps answer Mantel") {
                let rows = model.reachRows
                if rows.isEmpty {
                    Text(HidingDiagnostics.noReachText).foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    HStack {
                        Text(row.name).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(row.text).foregroundStyle(row.status == .fine ? Color.secondary : Color.orange)
                    }
                }
            }
            Section {
                HStack {
                    Button("Copy diagnostics") { Task { await model.copy() } }
                    // Two lines are kept for what it says, so that the button doesn't move when there is something to say.
                    Text(model.message ?? " ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            // Picks up what changes while the pane is open: a permission switched in System Settings, a journal entry restored.
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// "Refresh menu bar" and "Reset menu bar…", under the checks, and what the last of them said. The buttons don't move: the room for the
    /// spinner and for two lines of what was said is kept whether or not there is anything in it.
    private var menuBarControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Refresh menu bar") { Task { await model.refreshMenuBar() } }
                Button("Reset menu bar…") { Task { await model.resetMenuBar() } }
                ProgressView()
                    .controlSize(.small)
                    .opacity(model.menuBarBusy ? 1 : 0)
                    .accessibilityHidden(!model.menuBarBusy)
            }
            .disabled(model.menuBarBusy)
            Text(model.menuBarMessage ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
    }
}

private struct CheckRow: View {
    let row: DiagnosticsRow
    let model: DiagnosticsModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: Self.symbol(row.check.status))
                .foregroundStyle(Self.color(row.check.status))
                .accessibilityLabel(row.check.status.word)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.check.title).font(.headline)
                Text(Self.shown(row.check.detail)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            switch row.kind {
            case .journal:
                Button("Replay now") { Task { await model.replayNow() } }
                    .disabled(model.isReplaying || row.check.status == .ok)
            case .logFile:
                Button("Show in Finder") { model.showLog() }
            default:
                EmptyView()
            }
        }
    }

    /// Paths are written with `~` for the home folder, as the copied report writes them.
    private static func shown(_ detail: String) -> String {
        DiagnosticsText.redact(detail, home: DiagnosticsReport.homeFolder)
    }

    static func symbol(_ status: DiagnosticsCheck.Status) -> String {
        switch status {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }

    static func color(_ status: DiagnosticsCheck.Status) -> Color {
        switch status {
        case .ok: .green
        case .warning: .orange
        case .problem: .red
        case .unknown: .secondary
        }
    }
}
