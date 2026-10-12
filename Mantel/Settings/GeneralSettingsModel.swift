import MKCore
import Observation

/// The general settings as the panes draw them: a copy the coordinator keeps in step with what it has saved, so that a change redraws
/// the controls that show it. The coordinator is where a change is made (`AppCoordinator.updateGeneralSettings`), which saves it and
/// passes it on to the menu bar; a pane never writes here.
@MainActor
@Observable
final class GeneralSettingsModel {
    private(set) var settings = GeneralSettings()

    func set(_ settings: GeneralSettings) {
        guard settings != self.settings else { return }
        self.settings = settings
    }
}
