import SwiftUI

/// The Settings window's contents: the panes in a sidebar, the chosen one beside it.
struct SettingsView: View {
    let model: SettingsModel
    let coordinator: AppCoordinator

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.available, selection: Binding<SettingsPane?>(
                get: { model.selection },
                set: { if let pane = $0 { model.select(pane) } }
            )) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            detail(for: model.selection)
                .navigationTitle(model.selection.title)
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    @ViewBuilder
    private func detail(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralPane(coordinator: coordinator)
        case .layout: LayoutPane(coordinator: coordinator)
        case .hotkeys: HotkeysPane(coordinator: coordinator)
        case .permissions:
            PermissionsPane(checker: coordinator.permissionChecker, grants: coordinator.grants,
                            fileGranted: { coordinator.permissionsChanged() })
        case .advanced: AdvancedPane(coordinator: coordinator)
        case .diagnostics: DiagnosticsPane(coordinator: coordinator)
        case .about: AboutPane()
        }
    }
}
