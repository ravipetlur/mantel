import AppKit
import SwiftUI

struct AboutPane: View {
    private static let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
        ?? "Copyright © The Mantel Authors. Apache License 2.0."

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Mantel").font(.largeTitle.bold())
            Text("Version \(Bundle.main.versionString)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(Self.copyright)
                .foregroundStyle(.secondary)
            Link("whittled.dev", destination: URL(string: "https://whittled.dev")!)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}
