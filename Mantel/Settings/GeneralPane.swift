import MKCore
import SwiftUI

struct GeneralPane: View {
    let coordinator: AppCoordinator

    var body: some View {
        let reveal = coordinator.settingsModel.settings.reveal
        Form {
            Section("Startup") {
                LaunchAtLoginToggle()
            }
            Section {
                SettingsToggle("Show hidden icons when the pointer rests on empty menu bar space", isOn: Binding(
                    get: { coordinator.settingsModel.settings.reveal.hoverReveals },
                    set: { value in coordinator.updateGeneralSettings { $0.reveal.hoverReveals = value } }))
                Picker("Delay before showing", selection: Binding(
                    get: { coordinator.settingsModel.settings.reveal.hoverDelayMilliseconds },
                    set: { value in coordinator.updateGeneralSettings { $0.reveal.hoverDelayMilliseconds = value } })
                ) {
                    ForEach(RevealChoices.hoverDelays) { option in
                        Text(option.title).tag(option.value)
                    }
                }
                .disabled(!reveal.hoverReveals)
                SettingsToggle("Show hidden icons when you click empty menu bar space", isOn: Binding(
                    get: { coordinator.settingsModel.settings.reveal.clickReveals },
                    set: { value in coordinator.updateGeneralSettings { $0.reveal.clickReveals = value } }))
                SettingsToggle("Show hidden icons when you scroll on the menu bar", isOn: Binding(
                    get: { coordinator.settingsModel.settings.reveal.scrollReveals },
                    set: { value in coordinator.updateGeneralSettings { $0.reveal.scrollReveals = value } }))
                Picker("Hide again after", selection: Binding(
                    get: { coordinator.settingsModel.settings.reveal.rehide },
                    set: { value in coordinator.updateGeneralSettings { $0.reveal.rehide = value } })
                ) {
                    ForEach(RevealChoices.rehideDelays) { option in
                        Text(option.title).tag(option.value)
                    }
                }
            } header: {
                Text("Revealing")
            } footer: {
                Text("Icons stay out while a menu is open or the pointer is in the menu bar.")
            }
            Section("Welcome") {
                Button("Show welcome again") { coordinator.openOnboarding() }
            }
        }
        .formStyle(.grouped)
    }
}
