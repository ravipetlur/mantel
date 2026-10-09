import SwiftUI

struct GeneralPane: View {
    let coordinator: AppCoordinator

    var body: some View {
        Form {
            Section("Startup") {
                LaunchAtLoginToggle()
            }
            Section("Welcome") {
                Button("Show welcome again") { coordinator.openOnboarding() }
            }
        }
        .formStyle(.grouped)
    }
}
