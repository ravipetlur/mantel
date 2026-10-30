import AppKit
import MKCore
import SwiftUI

/// One row for each permission Mantel may need: its name, why, where it stands, and a button to the place it is given.
struct PermissionsPane: View {
    let checker: any PermissionChecking
    let grants: FileGrantStore
    /// Called when the person has chosen a file and Mantel keeps it: what depends on the file is asked again.
    let fileGranted: () -> Void
    @State private var states: [PermissionKind: PermissionState] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(PermissionKind.allCases, id: \.self) { kind in
                    PermissionRow(info: PermissionInfo.info(for: kind), state: states[kind]) {
                        act(on: kind)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            // Picks up what the person switches in System Settings while this pane is open.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refresh() async {
        var fresh: [PermissionKind: PermissionState] = [:]
        for kind in PermissionKind.allCases {
            fresh[kind] = await checker.state(of: kind)
        }
        // Set only when something changed, so that the pane isn't redrawn every two seconds for nothing.
        if fresh != states { states = fresh }
    }

    private func act(on kind: PermissionKind) {
        if let fileKind = kind.fileGrantKind {
            Task { await chooseFile(for: fileKind) }
            return
        }
        if kind == .accessibility {
            // Asks once; the pane then opens either way.
            AccessibilityTrust.promptAndOpenSettings()
        } else if let url = PermissionInfo.info(for: kind).settingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// The person picks the file in an open panel, and Mantel keeps it (`FileGrantPanel`).
    private func chooseFile(for kind: FileGrantKind) async {
        if await FileGrantPanel.choose(kind, grants: grants) { fileGranted() }
        await refresh()
    }
}

private struct PermissionRow: View {
    let info: PermissionInfo
    /// Nil until the first read.
    let state: PermissionState?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title).font(.headline)
                Text(info.reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let state {
                BadgeView(badge: PermissionBadge.make(state: state, kind: info.kind))
            }
            Button(info.kind.fileGrantKind == nil ? "Open System Settings" : "Choose file…", action: action)
        }
    }
}

private struct BadgeView: View {
    let badge: PermissionBadge

    private var color: Color {
        switch badge.tone {
        case .good: .green
        case .warning: .orange
        case .neutral: .secondary
        }
    }

    var body: some View {
        Text(badge.title)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
    }
}
