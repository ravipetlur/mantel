import MKLayout
import MKMenuBar
import SwiftUI

/// The banner at the top of the Layout pane: why reordering isn't available, or what the last change came to, one line each
/// (`LayoutBannerModel`). A line that says what a refused drop was flashes when one happens: there is no alert for it.
struct LayoutBanner: View {
    let lines: [LayoutBannerLine]
    /// The text of the refusal that is flashing, if one is.
    let flashing: String?
    /// Has the person choose the layout file.
    let grantAccess: () -> Void

    var body: some View {
        if !lines.isEmpty {
            Section {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        // The row that holds a refusal's place is as tall as the longest refusal a drag says, and shows nothing.
                        Text(line.isPlaceholder ? LayoutEditorCopy.cantPlaceThisIcon : line.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if line.offersGrant {
                            Button(LayoutCopy.grantAccessButton, action: grantAccess)
                        }
                    }
                    .opacity(line.isPlaceholder ? 0 : 1)
                    .accessibilityHidden(line.isPlaceholder)
                    .listRowBackground(flashing == line.text ? Color.accentColor.opacity(0.22) : nil)
                    .animation(.easeInOut(duration: 0.25), value: flashing)
                }
            }
        }
    }
}
