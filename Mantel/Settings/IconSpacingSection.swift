import MKCore
import MKMenuBar
import SwiftUI

/// What Settings › Advanced › Icon spacing shows and does: the two spacing keys as the writer reads them, and the changes the person makes.
/// A change is written at once and kept (`SpacingWriter`); the apps that are open pick it up when they next start.
@MainActor
@Observable
final class IconSpacingModel {
    private let coordinator: AppCoordinator
    private(set) var state: SpacingState?
    /// What the "Spacing" and "Padding" fields show while they are typed in. The keys change only when a field is committed.
    var spacingDraft: ClampedNumberDraft
    var paddingDraft: ClampedNumberDraft
    /// Custom was picked and its values haven't been written yet: the fields show, and nothing is written until one is committed.
    private(set) var pickedCustom = false
    private(set) var isBusy = false
    /// What the last change that failed says, until the next action.
    private(set) var failure: String?

    private static let format = ClampedIntegerFormat(range: IconSpacingValues.range)
    /// What the fields start at when no spacing is set: the values of Small.
    private static let starting = IconSpacingValues(spacing: 8, padding: 8)

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        spacingDraft = ClampedNumberDraft(committed: Self.starting.spacing, format: Self.format)
        paddingDraft = ClampedNumberDraft(committed: Self.starting.padding, format: Self.format)
    }

    /// The preset the picker shows.
    var preset: IconSpacingPreset {
        pickedCustom ? .custom : state?.preset ?? .macOSDefault
    }

    /// Whether "Restore original spacing" has something to put back.
    var canRestore: Bool { state?.original != nil && !isBusy }

    func refresh() async {
        let current = await coordinator.spacingWriter.current()
        state = current
        // The fields show what the keys hold (a key with no number keeps what its field had).
        let shown = IconSpacingValues(spacing: current.spacing ?? spacingDraft.committed, padding: current.padding ?? paddingDraft.committed).clamped
        spacingDraft.follow(shown.spacing)
        paddingDraft.follow(shown.padding)
    }

    /// A preset was picked. Custom shows the fields and writes when one of them is committed; every other preset is written now.
    func choose(_ preset: IconSpacingPreset) async {
        guard !isBusy else { return }
        failure = nil
        if preset == .custom {
            pickedCustom = true
            return
        }
        pickedCustom = false
        await apply(preset)
    }

    /// A field was committed: both numbers are written as Custom, when one of them is different, or when Custom was picked and the keys
    /// don't hold what the fields show yet (the same number typed over itself is still the first write).
    func commitCustom() async {
        let changedSpacing = spacingDraft.commit() != nil
        let changedPadding = paddingDraft.commit() != nil
        let unwritten = pickedCustom && (state?.spacing != spacingDraft.committed || state?.padding != paddingDraft.committed)
        guard changedSpacing || changedPadding || unwritten else { return }
        failure = nil
        await apply(.custom)
    }

    func restoreOriginal() async {
        guard canRestore else { return }
        isBusy = true
        failure = nil
        let failures = await coordinator.spacingWriter.restoreOriginal()
        if !failures.isEmpty {
            Log.warning("settings", "\(failures.count) icon spacing keys weren't put back")
            failure = "Couldn't put the original spacing back. Try again."
        }
        pickedCustom = false
        isBusy = false
        await refresh()
    }

    private func apply(_ preset: IconSpacingPreset) async {
        isBusy = true
        do {
            try await coordinator.spacingWriter.apply(
                preset, custom: IconSpacingValues(spacing: spacingDraft.committed, padding: paddingDraft.committed))
        } catch {
            Log.warning("settings", "icon spacing wasn't changed: \(error.localizedDescription)")
            failure = "Couldn't change the icon spacing. Try again."
        }
        isBusy = false
        await refresh()
    }
}

/// Settings › Advanced › Icon spacing: a picker of the presets, the two numbers of Custom, and the buttons that relaunch the apps that draw
/// icons and put the original spacing back. It is off, with a line that says why, on a Mac where macOS doesn't apply the spacing.
struct IconSpacingSection: View {
    let coordinator: AppCoordinator
    @State private var model: IconSpacingModel
    @State private var isShowingRelaunch = false
    @FocusState private var focused: Field?

    private enum Field: Hashable { case spacing, padding }

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _model = State(initialValue: IconSpacingModel(coordinator: coordinator))
    }

    var body: some View {
        Section {
            Picker("Icon spacing", selection: Binding(get: { model.preset }, set: { preset in Task { await model.choose(preset) } })) {
                ForEach(IconSpacingPreset.allCases, id: \.self) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            if model.preset == .custom {
                numberField("Spacing", draft: $model.spacingDraft, field: .spacing)
                numberField("Padding", draft: $model.paddingDraft, field: .padding)
            }
            HStack(spacing: 8) {
                Button("Relaunch Apps…") { isShowingRelaunch = true }
                    .disabled(relaunchCandidates().isEmpty)
                Button("Restore original spacing") { Task { await model.restoreOriginal() } }
                    .disabled(!model.canRestore)
            }
            if let failure = model.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if !IconSpacing.macOSApplies {
                Text(IconSpacing.notAppliedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Icon spacing")
        } footer: {
            Text("macOS applies this to other apps' icons when they next open. Mantel's own icons change when Mantel next starts.")
        }
        .disabled(!IconSpacing.macOSApplies)
        .task { await model.refresh() }
        .sheet(isPresented: $isShowingRelaunch) {
            RelaunchSheet(model: RelaunchModel(candidates: relaunchCandidates(), relauncher: coordinator.appRelauncher,
                                               fresh: { relaunchCandidates() }))
        }
    }

    /// The apps that draw icons and can be relaunched: running, and neither Mantel nor one of Apple's.
    private func relaunchCandidates() -> [RelaunchCandidate] {
        guard let inventory = coordinator.menuBar?.model.state?.inventory else { return [] }
        return RelaunchPlan.candidates(inventory: inventory, running: coordinator.runningApps.all,
                                       ownBundleID: Bundle.main.bundleIdentifier ?? "com.example.mantel")
    }

    /// A number field: a title and the field side by side (an `HStack`), committed on Return or when the field is left, never on a key.
    private func numberField(_ title: String, draft: Binding<ClampedNumberDraft>, field: Field) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .accessibilityHidden(true)
            Spacer()
            TextField(title, text: draft.text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 64)
                .focused($focused, equals: field)
                .onSubmit { Task { await model.commitCustom() } }
                .onChange(of: focused) { old, _ in
                    if old == field { Task { await model.commitCustom() } }
                }
                .accessibilityLabel(title)
        }
    }
}
