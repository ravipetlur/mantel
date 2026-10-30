import MKMenuBar
import SwiftUI

/// What the relaunch sheet holds and does: the apps offered, which are ticked, and how each came out once Relaunch is pressed.
///
/// Nothing is ticked when the sheet opens, and the apps are asked one after the other, each to quit politely and then opened again without
/// being brought forward (`AppRelaunching`). Cancel while it runs stops it between apps (`RelaunchRun`) and the sheet closes once the app
/// being relaunched has its outcome: nothing is cancelled, so an app that was asked to quit is never left unopened. An app that was relaunched
/// is unticked and stays so (`RelaunchSelection.finish`); one that didn't quit or couldn't be opened can be tried again.
@MainActor
@Observable
final class RelaunchModel {
    let candidates: [RelaunchCandidate]
    private(set) var selection: RelaunchSelection
    /// How each app that has been dealt with came out, by bundle ID.
    private(set) var outcomes: [String: RelaunchOutcome] = [:]
    /// The app being relaunched now.
    private(set) var current: String?
    private(set) var isRunning = false
    /// Whether the sheet is to close: a stop was asked for and the run has ended.
    private(set) var shouldClose = false
    private var run = RelaunchRun(chosen: [])
    private let relauncher: any AppRelaunching
    /// The offered apps as they are now, for the process ID of an app that is tried again (the one the list was made with may be gone).
    private let fresh: @MainActor () -> [RelaunchCandidate]

    init(candidates: [RelaunchCandidate], relauncher: any AppRelaunching, fresh: @escaping @MainActor () -> [RelaunchCandidate]) {
        self.candidates = candidates
        self.relauncher = relauncher
        self.fresh = fresh
        selection = RelaunchSelection(candidates: candidates)
    }

    /// Whether Cancel has been pressed while the run is going.
    var isStopping: Bool { isRunning && run.stopRequested }

    /// Whether the sheet shows how some apps came out, which makes its button "Done".
    var hasOutcomes: Bool { !outcomes.isEmpty }

    func isRelaunched(_ candidate: RelaunchCandidate) -> Bool { selection.relaunched.contains(candidate.id) }

    /// Cancel while the apps are being relaunched: no app after the current one is started.
    func stop() {
        guard isRunning else { return }
        run.requestStop()
    }

    var canRelaunch: Bool { selection.canRelaunch && !isRunning }

    func isTicked(_ candidate: RelaunchCandidate) -> Bool { selection.ticked.contains(candidate.id) }

    func toggle(_ candidate: RelaunchCandidate) {
        guard !isRunning else { return }
        selection.toggle(candidate.id)
    }

    func selectAll() {
        guard !isRunning else { return }
        selection.selectAll()
    }

    func relaunch() async {
        guard canRelaunch else { return }
        isRunning = true
        for candidate in selection.chosen { outcomes[candidate.id] = nil }
        run = RelaunchRun(chosen: selection.chosen)
        while let candidate = run.next() {
            current = candidate.id
            let now = fresh().first { $0.id == candidate.id } ?? candidate
            outcomes[candidate.id] = await relauncher.relaunch(now)
        }
        current = nil
        selection.finish(outcomes)
        isRunning = false
        if run.stopRequested { shouldClose = true }
    }
}

/// The sheet Settings › Advanced › Icon spacing opens from "Relaunch Apps…": the apps that draw icons, to tick, and Relaunch.
struct RelaunchSheet: View {
    @State var model: RelaunchModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Relaunch apps with icons")
                .font(.headline)
            List(model.candidates) { candidate in
                HStack(spacing: 8) {
                    Toggle(candidate.name, isOn: Binding(get: { model.isTicked(candidate) }, set: { _ in model.toggle(candidate) }))
                        .toggleStyle(.checkbox)
                        .disabled(model.isRunning || model.isRelaunched(candidate))
                    Spacer(minLength: 8)
                    if model.current == candidate.id {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Relaunching")
                    } else if let outcome = model.outcomes[candidate.id] {
                        Text(outcome.rowText).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.bordered)
            Button("Select All") { model.selectAll() }
                .disabled(model.isRunning)
            Text("Each app you tick is asked to quit and then opened again. Apps that ask to save first are left as they are.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("Mantel's own icons change when Mantel next starts.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button {
                    if model.isRunning { model.stop() } else { dismiss() }
                } label: {
                    // Both labels, unseen, with the one in force on top: the button keeps one width when it turns to "Done".
                    ZStack {
                        Text("Cancel").hidden().accessibilityHidden(true)
                        Text("Done").hidden().accessibilityHidden(true)
                        Text(model.hasOutcomes && !model.isRunning ? "Done" : "Cancel")
                    }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isStopping)
                Button("Relaunch") { Task { await model.relaunch() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canRelaunch)
            }
        }
        .padding(20)
        .frame(width: 440, height: 360)
        .interactiveDismissDisabled(model.isRunning)
        .onChange(of: model.shouldClose) { _, close in
            if close { dismiss() }
        }
    }
}
