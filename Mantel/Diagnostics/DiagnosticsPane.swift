import AppKit
import MKCommands
import MKCore
import MKMenuBar
import SwiftUI

/// What the Diagnostics pane shows and does. Nothing in it is saved: the platform test switch starts off each time the pane
/// is opened.
@MainActor
@Observable
final class DiagnosticsModel {
    private let coordinator: AppCoordinator

    private(set) var rows: [DiagnosticsRow] = []
    private(set) var reports: [ProbeName: ProbeReport] = [:]
    /// The probe that is running now.
    private(set) var running: ProbeName?
    /// What the last button said happened: "Copied", or how the replay ended.
    private(set) var message: String?
    private(set) var isReplaying = false
    /// Whether the probes that change the menu bar can be run. Off whenever the pane is opened, and not kept.
    var platformTestEnabled = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func refresh() async {
        let fresh = await DiagnosticsReport.rows(for: coordinator)
        // Set only when something changed, so that the pane isn't redrawn every two seconds for nothing.
        if fresh.map(\.check) != rows.map(\.check) { rows = fresh }
    }

    func refreshReports() async {
        reports = await coordinator.probes.latestReports()
    }

    func run(_ name: ProbeName) async {
        guard running == nil else { return }
        running = name
        message = nil
        // Without options: the test item is the only app a probe touches.
        let report = await coordinator.runProbe(name, options: ProbeOptions([:]))
        running = nil
        if let first = report?.errors.first { message = "\(name.rawValue): \(first)" }
        await refreshReports()
        await refresh()
    }

    func replayNow() async {
        guard !isReplaying else { return }
        isReplaying = true
        message = await coordinator.replayJournalNow()
        isReplaying = false
        await refresh()
    }

    func copy() async {
        await refreshReports()
        await refresh()
        let text = DiagnosticsReport.text(rows: rows, probes: reports)
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

/// The checks, "Copy diagnostics", and the platform test: a button for each probe.
struct DiagnosticsPane: View {
    @State private var model: DiagnosticsModel

    init(coordinator: AppCoordinator) {
        _model = State(initialValue: DiagnosticsModel(coordinator: coordinator))
    }

    var body: some View {
        Form {
            Section("Checks") {
                ForEach(model.rows) { row in
                    CheckRow(row: row, model: model)
                }
            }
            Section {
                HStack {
                    Button("Copy diagnostics") { Task { await model.copy() } }
                    if let message = model.message {
                        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            Section("Platform test") {
                Toggle("Enable platform test (changes your menu bar briefly)", isOn: $model.platformTestEnabled)
                ForEach(ProbeName.allCases, id: \.self) { name in
                    ProbeRow(name: name, report: model.reports[name], model: model)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await model.refreshReports()
            // Picks up what changes while the pane is open: a permission switched in System Settings, a journal entry restored.
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
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

private struct ProbeRow: View {
    let name: ProbeName
    let report: ProbeReport?
    let model: DiagnosticsModel

    private var changesMenuBar: Bool { ProbeRunner.changesState(name) }
    /// A probe that changes the menu bar waits for the switch; the others can always be run.
    private var isAvailable: Bool { model.running == nil && (!changesMenuBar || model.platformTestEnabled) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name.rawValue).font(.body.monospaced())
                if let report {
                    Text(ProbeSummary.line(for: report)).font(.caption).foregroundStyle(.secondary)
                    if let error = report.errors.first {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                } else {
                    Text("Not run yet").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.running == name {
                ProgressView().controlSize(.small)
            } else if changesMenuBar {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    .help("Changes your menu bar briefly").accessibilityLabel("Changes your menu bar briefly")
            }
            Button("Run") { Task { await model.run(name) } }
                .disabled(!isAvailable)
        }
    }
}
