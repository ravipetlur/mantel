import MKCommands
import SwiftUI

/// The Settings window's contents: the pages in a sidebar, the chosen one's pane beside it.
struct SettingsView: View {
    let model: SettingsModel
    let coordinator: AppCoordinator

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, id: \.self, selection: Binding<SettingsPage?>(
                get: { model.selection },
                set: { if let page = $0 { model.select(page) } }
            )) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            SettingsPane(page: model.selection, coordinator: coordinator)
                .navigationTitle(model.selection.title)
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}
