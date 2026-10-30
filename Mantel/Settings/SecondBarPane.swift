import MKCore
import SwiftUI

/// Settings › Second bar: when it opens, where it goes and how it looks, with a picture of the look.
struct SecondBarPane: View {
    let coordinator: AppCoordinator

    /// The colour a glass tint starts as when the person turns it on.
    private static let startingTint = RGBAColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 0.35)
    /// The colour a border starts as when the person turns it on: the one a border without a colour is read as.
    private static let startingBorder = RGBAColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.5)

    private var secondBar: SecondBarSettings { coordinator.settingsModel.settings.secondBar }
    private var style: PanelStyle { secondBar.style }

    var body: some View {
        Form {
            openingSection
            lookSection
            Section("Preview") {
                HStack {
                    Spacer()
                    PanelStylePreview(style: style)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
        .formStyle(.grouped)
    }

    private func edit(_ change: (inout SecondBarSettings) -> Void) {
        coordinator.updateGeneralSettings { change(&$0.secondBar) }
    }

    /// A change to the style as it is when the change runs, not as it was when the control was drawn: what a control writes applies only
    /// if the background is still the kind it edits (a field that disappears commits what it holds, after the kind has changed).
    private func editStyle(_ change: (inout PanelStyle) -> Void) {
        edit { change(&$0.style) }
    }

    // MARK: Opening

    private var openingSection: some View {
        Section {
            Picker("Opening", selection: Binding(get: { secondBar.opens }, set: { value in edit { $0.opens = value } })) {
                Text("Only when hidden icons don't fit").tag(SecondBarOpening.whenNoRoom)
                Text("Always, instead of showing them in the menu bar").tag(SecondBarOpening.always)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Picker("Position", selection: Binding(get: { secondBar.position }, set: { value in edit { $0.position = value } })) {
                Text("Under the dot").tag(SecondBarPosition.underDot)
                Text("At the right of the menu bar").tag(SecondBarPosition.rightAligned)
            }
        } header: {
            Text("Opening")
        } footer: {
            Text("The second bar's hotkey opens it under the pointer.")
        }
    }

    // MARK: Look

    private var lookSection: some View {
        Section("Look") {
            Picker("Background", selection: Binding(get: { style.backgroundKind },
                                                    set: { kind in editStyle { $0 = $0.withBackgroundKind(kind) } })) {
                Text("Match the menu bar").tag(PanelBackgroundKind.matchMenuBar)
                Text("Glass").tag(PanelBackgroundKind.glass)
                Text("Material").tag(PanelBackgroundKind.material)
                Text("Solid colour").tag(PanelBackgroundKind.solid)
                Text("Gradient").tag(PanelBackgroundKind.gradient)
            }
            backgroundControls
            Picker("Appearance", selection: Binding(get: { style.appearance }, set: { value in editStyle { $0.appearance = value } })) {
                Text("Match the menu bar").tag(PanelAppearance.matchMenuBar)
                Text("Light").tag(PanelAppearance.light)
                Text("Dark").tag(PanelAppearance.dark)
            }
            borderControls
            SettingsToggle("Shadow", isOn: Binding(get: { style.shadow }, set: { value in editStyle { $0.shadow = value } }))
        }
    }

    @ViewBuilder
    private var backgroundControls: some View {
        switch style.background {
        case .matchMenuBar:
            EmptyView()
        case .glass(let tint):
            HStack(spacing: 8) {
                SettingsToggle("Tint", isOn: Binding(
                    get: { tint != nil },
                    set: { on in
                        editStyle {
                            guard case .glass(let current) = $0.background else { return }
                            $0.background = .glass(tint: on ? (current ?? Self.startingTint) : nil)
                        }
                    }))
                if let tint {
                    SettingsColorPicker("Tint colour", showsTitle: false, color: tint) { color in
                        editStyle { if case .glass = $0.background { $0.background = .glass(tint: color) } }
                    }
                }
            }
        case .material(let thickness):
            Picker("Thickness", selection: Binding(get: { thickness }, set: { value in editStyle { if case .material = $0.background { $0.background = .material(value) } } })) {
                Text("Ultra thin").tag(MaterialThickness.ultraThin)
                Text("Thin").tag(MaterialThickness.thin)
                Text("Regular").tag(MaterialThickness.regular)
                Text("Thick").tag(MaterialThickness.thick)
                Text("Ultra thick").tag(MaterialThickness.ultraThick)
            }
        case .solid(let color):
            SettingsColorPicker("Solid colour", color: color) { color in
                editStyle { if case .solid = $0.background { $0.background = .solid(color) } }
            }
        case .gradient(let from, let to, let angle):
            SettingsColorPicker("From", color: from) { color in
                editStyle { if case .gradient(_, let to, let angle) = $0.background { $0.background = .gradient(from: color, to: to, angle: angle) } }
            }
            SettingsColorPicker("To", color: to) { color in
                editStyle { if case .gradient(let from, _, let angle) = $0.background { $0.background = .gradient(from: from, to: color, angle: angle) } }
            }
            GradientAngleField(angle: angle) { value in
                editStyle { if case .gradient(let from, let to, _) = $0.background { $0.background = .gradient(from: from, to: to, angle: value) } }
            }
        }
    }

    @ViewBuilder
    private var borderControls: some View {
        HStack(spacing: 8) {
            SettingsToggle("Border", isOn: Binding(
                get: { style.border != nil },
                set: { on in editStyle { $0.border = on ? PanelBorder(color: Self.startingBorder) : nil } }))
            if let border = style.border {
                SettingsColorPicker("Border colour", showsTitle: false, color: border.color) { color in editStyle { $0.border?.color = color } }
            }
        }
        if let border = style.border {
            HStack(spacing: 8) {
                Text("Width")
                    .accessibilityHidden(true)
                Spacer()
                // A stepper isn't a typed number: each step is saved at once. VoiceOver reads the stepper with its value, so the two
                // texts beside it are hidden.
                Text("\(border.width) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Stepper("Width", value: Binding(get: { border.width }, set: { width in editStyle { $0 = $0.withBorderWidth(width) } }),
                        in: PanelBorder.widthRange)
                    .labelsHidden()
                    .accessibilityValue("\(border.width) pt")
            }
        }
    }
}

/// The gradient's angle: a number field with a stepper. What is typed is only text until the field is committed (Return, or leaving it),
/// so an angle can be typed a digit at a time.
private struct GradientAngleField: View {
    private static let format = ClampedIntegerFormat(range: 0...359)

    let angle: Int
    let save: (Int) -> Void
    @State private var draft: ClampedNumberDraft
    @FocusState private var isFocused: Bool

    init(angle: Int, save: @escaping (Int) -> Void) {
        self.angle = angle
        self.save = save
        _draft = State(initialValue: ClampedNumberDraft(committed: angle, format: Self.format))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Angle")
                .accessibilityHidden(true)
            Spacer()
            TextField("Angle", text: $draft.text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 64)
                .focused($isFocused)
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                .onDisappear(perform: commit)
            Stepper("Angle", value: Binding(get: { angle }, set: { value in save(value) }), in: 0...359)
                .labelsHidden()
        }
        // The angle changed some way other than typing (the stepper): the text follows it.
        .onChange(of: angle) { _, number in draft.follow(number) }
    }

    private func commit() {
        if let number = draft.commit() { save(number) }
    }
}
