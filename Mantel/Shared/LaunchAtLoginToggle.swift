import MKCore
import ServiceManagement
import SwiftUI

/// The launch-at-login toggle used in Settings. The binding's setter registers or unregisters exactly once; refreshing
/// the state never calls it again.
struct LaunchAtLoginToggle: View {
    @State private var state = LoginItemState(SMAppService.mainApp.status)
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsToggle("Launch at login", isOn: Binding(get: { state.isOn }, set: setEnabled))
            if state == .requiresApproval {
                HStack(spacing: 8) {
                    Text(LoginItemFeedback.approvalMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                        .controlSize(.small)
                }
            }
        }
        .task {
            // Picks up approval (or removal) made in System Settings while this view is open.
            while !Task.isCancelled {
                state = LoginItemState(SMAppService.mainApp.status)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .alert("Couldn't change launch at login",
               isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.error("login-item", "Launch at login (\(enabled ? "on" : "off")) failed: \(error)")
            errorMessage = LoginItemFeedback.message(for: error)
        }
        state = LoginItemState(SMAppService.mainApp.status)
    }
}
