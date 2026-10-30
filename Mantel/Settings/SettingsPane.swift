import MKCommands
import SwiftUI

/// The pane Settings shows for a page: each case of `SettingsPage` is mapped to its pane here, one to one. The switch has no `default`, so
/// a page that is added to the list doesn't build until it has a pane.
struct SettingsPane: View {
    let page: SettingsPage
    let coordinator: AppCoordinator

    var body: some View {
        switch page {
        case .general: GeneralPane(coordinator: coordinator)
        case .layout: LayoutPane(coordinator: coordinator)
        case .secondBar: SecondBarPane(coordinator: coordinator)
        case .hotkeys: HotkeysPane(coordinator: coordinator)
        case .cosmetics: CosmeticsPane(coordinator: coordinator)
        case .permissions:
            PermissionsPane(checker: coordinator.permissionChecker, grants: coordinator.grants,
                            fileGranted: { coordinator.permissionsChanged() })
        case .advanced: AdvancedPane(coordinator: coordinator)
        case .diagnostics: DiagnosticsPane(coordinator: coordinator)
        case .about: AboutPane(coordinator: coordinator)
        }
    }
}
