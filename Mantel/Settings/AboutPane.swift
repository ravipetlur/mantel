import AppKit
import SwiftUI

/// Settings › About: the app, its version, who it belongs to, and where to find more.
struct AboutPane: View {
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
        }
        .formStyle(.grouped)
    }
}
