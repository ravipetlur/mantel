import MKCore
import MKMenuBar
import SwiftUI

/// Settings › Advanced: how icons are hidden and when, and what the room on the bar is made for.
///
/// - **How icons are hidden** is what `HidingMethodRows` says: a way that can't be used now is dimmed and says why, and "Now using" is the
///   engine's own words. While a switch to another way is under way the choices are dimmed and the line says "Switching to …" with a
///   spinner. They come from the menu bar model (the session's last state), so nothing here polls.
/// - **Allowing the clock and Control Center to be hidden asks first**; turning it off never does.
struct AdvancedPane: View {
    let coordinator: AppCoordinator
    @State private var isAskingToAllowClock = false
    /// What the "Wider than" field shows while it is typed in. The setting changes only when the field is committed (`commitThreshold`).
    @State private var thresholdDraft: ClampedNumberDraft
    @FocusState private var thresholdIsFocused: Bool

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _thresholdDraft = State(initialValue: ClampedNumberDraft(
            committed: coordinator.settingsModel.settings.hiding.wideScreenThreshold, format: HidingSettings.wideScreenThresholdFormat))
    }

    var body: some View {
        let hiding = coordinator.settingsModel.settings.hiding
        let engine = coordinator.menuBar?.model.state?.engine
        Form {
            hidingSection(hiding: hiding, engine: engine)
            noRoomSection(hiding: hiding)
            wideScreensSection(hiding: hiding)
            IconSpacingSection(coordinator: coordinator)
        }
        .formStyle(.grouped)
        .alert(AdvancedCopy.allowClockTitle, isPresented: $isAskingToAllowClock) {
            Button(AdvancedCopy.allowClockConfirm) {
                coordinator.updateGeneralSettings { $0.hiding.allowHidingClockAndControlCenter = true }
            }
            Button(AdvancedCopy.allowClockCancel, role: .cancel) {}
        } message: {
            Text(AdvancedCopy.allowClockText)
        }
    }

    // MARK: Hiding

    private func hidingSection(hiding: HidingSettings, engine: EngineStatus?) -> some View {
        let presentation = HidingMethodRows.presentation(method: hiding.method, engine: engine)
        return Section {
            RadioGroup(
                label: "Hiding method", showsLabel: true,
                options: presentation.rows.map {
                    RadioOption(value: $0.choice, title: $0.title, caption: $0.caption, isEnabled: $0.isEnabled)
                },
                selection: Binding(
                    get: { hiding.method },
                    set: { method in coordinator.updateGeneralSettings { $0.hiding.method = method } }))
            if let nowUsing = presentation.nowUsing {
                nowUsingLine(nowUsing, switching: presentation.switching)
            }
            SettingsToggle("Allow hiding the clock and Control Center", isOn: Binding(
                get: { hiding.allowHidingClockAndControlCenter },
                set: { allowed in
                    // On asks first (the switch stays off until the answer is Allow); off never does.
                    if AdvancedCopy.asksBeforeAllowingClock(turningOn: allowed) {
                        isAskingToAllowClock = true
                    } else {
                        coordinator.updateGeneralSettings { $0.hiding.allowHidingClockAndControlCenter = false }
                    }
                }))
        } header: {
            Text("Hiding")
        } footer: {
            Text("Some system controls, like the volume pop-up, can stop working while these are hidden.")
        }
    }

    /// "Now using: …", or while a switch is under way "Switching to …" with a small spinner, until the engine has settled. Both are in the
    /// layout all the time, one over the other, so the line keeps the room of the longer and nothing moves when it changes.
    private func nowUsingLine(_ nowUsing: String, switching: String?) -> some View {
        ZStack(alignment: .topLeading) {
            Text(nowUsing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .opacity(switching == nil ? 1 : 0)
                .accessibilityHidden(switching != nil)
            if let switching {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(switching)
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: When hidden icons don't fit

    private func noRoomSection(hiding: HidingSettings) -> some View {
        Section("When hidden icons don't fit") {
            RadioGroup(
                label: "When hidden icons don't fit",
                options: NoRoomPolicy.allCases.map {
                    RadioOption(value: $0, title: AdvancedCopy.title(for: $0), caption: AdvancedCopy.caption(for: $0))
                },
                selection: Binding(
                    get: { hiding.noRoomPolicy },
                    set: { policy in coordinator.updateGeneralSettings { $0.hiding.noRoomPolicy = policy } }))
        }
    }

    // MARK: Wide screens

    /// The "Wider than" field is committed: what was typed is read and brought into range, saved when it is a different number, and the
    /// field shows the number that stands. A text that isn't a number leaves the setting as it was.
    private func commitThreshold() {
        if let number = thresholdDraft.commit() {
            coordinator.updateGeneralSettings { $0.hiding.wideScreenThreshold = number }
        }
    }

    private func wideScreensSection(hiding: HidingSettings) -> some View {
        Section {
            SettingsToggle("Show every icon on wide screens", isOn: Binding(
                get: { hiding.showEverythingOnWideScreens },
                set: { value in coordinator.updateGeneralSettings { $0.hiding.showEverythingOnWideScreens = value } }))
            // The stepper moves the setting by one step and writes it at once.
            let threshold = Binding(
                get: { hiding.wideScreenThreshold },
                set: { value in coordinator.updateGeneralSettings { $0.hiding.wideScreenThreshold = value } })
            LabeledContent("Wider than") {
                HStack(spacing: 8) {
                    // What is typed is only text until the field is committed (Return, or leaving the field): then it is read, brought into
                    // range and onto a step, and saved. Typing never saves, so a number can be typed a digit at a time.
                    TextField("Wider than", text: $thresholdDraft.text)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 64)
                        .focused($thresholdIsFocused)
                        .onSubmit(commitThreshold)
                        .onChange(of: thresholdIsFocused) { _, isFocused in
                            if !isFocused { commitThreshold() }
                        }
                        .onDisappear(perform: commitThreshold)
                    Stepper("Wider than", value: threshold, in: HidingSettings.wideScreenThresholdRange,
                            step: HidingSettings.wideScreenThresholdStep)
                        .labelsHidden()
                    Text("points").foregroundStyle(.secondary)
                }
            }
            // The setting changed some way other than typing (the stepper): the text follows it.
            .onChange(of: hiding.wideScreenThreshold) { _, number in
                thresholdDraft.follow(number)
            }
            .disabled(!hiding.showEverythingOnWideScreens)
        } header: {
            Text("Wide screens")
        } footer: {
            Text("Checked for the screen with the active menu bar.")
        }
    }
}
