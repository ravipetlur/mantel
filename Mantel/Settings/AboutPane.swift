import AppKit
import MKUpdate
import SwiftUI

/// Settings › About: the app, its version, who it belongs to, and where to find more.
struct AboutPane: View {
    let coordinator: AppCoordinator

    private static let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
        ?? "Copyright © The Mantel Authors. Apache License 2.0."

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mantel").font(.headline)
                        Text("Version \(Bundle.main.versionString)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text(Self.copyright)
                    .foregroundStyle(.secondary)
                Link("whittled.dev", destination: URL(string: "https://whittled.dev")!)
            }
            // A build that names no update repository has no updater, and shows none of this.
            if let updates = coordinator.updates {
                UpdateSection(coordinator: coordinator, updates: updates)
            }
        }
        .formStyle(.grouped)
    }
}

/// "Check for updates automatically", "Last checked: …", Check Now, and under them the answer to a check (`CheckAnswerLine`):
/// "Checking…", then "up to date", the reason a check failed, or the version that is available. The answer keeps a fixed
/// height, so nothing in the pane shifts as a check starts and ends, and it clears when the pane closes.
private struct UpdateSection: View {
    let coordinator: AppCoordinator
    let updates: UpdateCenter

    var body: some View {
        Section {
            SettingsToggle("Check for updates automatically", isOn: Binding(
                get: { coordinator.settingsModel.settings.checkForUpdatesAutomatically },
                set: { on in
                    coordinator.updateGeneralSettings { $0.checkForUpdatesAutomatically = on }
                    updates.automaticChecksChanged()
                }))
            HStack(spacing: 8) {
                // Re-read every half minute, so "5 minutes ago" keeps up.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(LastChecked.text(lastCheck: updates.lastCheck, now: context.date))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check Now") { updates.checkNow(from: .settings) }
                    .disabled(updates.isChecking)
            }
            CheckAnswerLine(answer: updates.aboutLine)
        }
        // The words that appear under the button are also said to VoiceOver.
        .onChange(of: updates.aboutLine?.title) { _, title in
            if let title { AccessibilityNotification.Announcement(title).post() }
        }
        .onDisappear { updates.aboutPaneClosed() }
    }
}
