import AppKit
import MKCore
import MKLayout
import SwiftUI

/// "Add to the menu bar": the three things that can be added, as tiles to drag into a strip. Each tile also has an "Add" menu that lists
/// the sections, for the keyboard and VoiceOver: a drag has no other way in.
struct PaletteSection: View {
    /// A palette item is added at the end of a section (the menu's equivalent of dropping it at the end of the strip).
    let add: (PaletteItem, MenuBarSection) -> Void
    /// A drag of a tile starts: what the drag carries.
    let drag: (EditorDrop) -> NSItemProvider

    var body: some View {
        Section {
            HStack(spacing: 12) {
                ForEach(PaletteItem.allCases, id: \.self) { item in
                    PaletteTile(item: item, add: add, drag: drag)
                }
            }
        } header: {
            Text(LayoutCopy.paletteHeader)
        } footer: {
            Text(LayoutCopy.paletteFooter)
        }
    }
}

private struct PaletteTile: View {
    let item: PaletteItem
    let add: (PaletteItem, MenuBarSection) -> Void
    /// A drag of a tile starts: what the drag carries.
    let drag: (EditorDrop) -> NSItemProvider

    var body: some View {
        VStack(spacing: 4) {
            VStack(spacing: 4) {
                Image(systemName: LayoutCopy.paletteSymbol(item))
                    .font(.title2)
                    .frame(height: 24)
                Text(LayoutCopy.paletteTitle(item))
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
            .contentShape(Rectangle())
            .onDrag({ drag(.palette(item)) }, preview: {
                Image(systemName: LayoutCopy.paletteSymbol(item)).font(.title2).padding(8)
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LayoutCopy.paletteTitle(item))

            Menu(LayoutCopy.add) {
                ForEach(MenuBarSection.allCases, id: \.self) { section in
                    Button(section.title) { add(item, section) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("\(LayoutCopy.add) \(LayoutCopy.paletteTitle(item))")
        }
        .frame(maxWidth: .infinity)
    }
}
