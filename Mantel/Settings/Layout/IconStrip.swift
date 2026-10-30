import AppKit
import MKCore
import MKLayout
import SwiftUI
import UniformTypeIdentifiers

/// What a drag of the editor carries. It is a type of its own and is kept in this process: text dragged in from another app isn't a drop
/// of the editor's, and a token can't be dropped into another app as text. What is being dragged is `LayoutPane`'s `dragging` (set when
/// the drag starts), so that a strip can tell while the pointer is over it whether the drop would be taken.
enum LayoutDrag {
    /// Declared in the app's Info.plist (`UTExportedTypeDeclarations`, from `project.yml`) as `$(PRODUCT_BUNDLE_IDENTIFIER).layout-drag`.
    static let type = UTType(exportedAs: "\(Bundle.main.bundleIdentifier ?? "mantel").layout-drag", conformingTo: .data)

    static func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(Data("layout".utf8), nil)
            return nil
        }
        return provider
    }
}

/// What the strips draw tokens from.
struct StripContext {
    let sections: SectionModel
    /// The apps' names by bundle ID.
    let names: [String: String]
    /// The apps whose place macOS gives Mantel no way to set: their tokens carry a quiet mark.
    let cantReorder: Set<String>
    /// What each app's row says of it (not answering, turned off in System Settings, an icon macOS doesn't tie to it), by bundle ID.
    let rows: [String: AppRow]
    let images: ItemImages
    let appearance: BarAppearance
    let widths: ItemWidthCache
    /// Where the pictures chosen for groups are kept.
    let ownImages: URL
}

/// A place a token can be moved to from its menu: a section's strip or a group's.
struct MoveTarget: Identifiable, Hashable {
    let strip: StripID
    let title: String

    var id: StripID { strip }
}

/// One strip of the layout editor: a section's or a group's icons in a row, as tokens that can be dragged (within the strip, to another
/// one, and from the palette) and clicked.
///
/// - **One view, one drop target.** The strip takes drops itself and works out where among its tokens one lands from where the pointer
///   is (`LayoutEditorModel.insertionIndex`): a drop destination on each token would never know the place between two of them, and a
///   drop on a section of a grouped form isn't a view.
/// - **A fixed height.** The strip is 44 points tall whatever is dragged over it or whatever it holds; the insertion line is an overlay.
/// - **Keyboard and VoiceOver.** The strip is a container of buttons named by their titles, and each has the menu equivalent of every drag
///   ("Move Left", "Move Right" and "Move to", and "Remove" for Mantel's own items), as a context menu and as accessibility actions.
/// - **What a drag may do.** The line is drawn where the drop lands (`LayoutEditorModel.landingPlace`: the pointer's place, or the nearest
///   that lands), and a drop is forbidden, with no line, where the model refuses it; a refusal is said in the banner, once for each time
///   a drag enters the strip.
struct IconStrip: View {
    let strip: Strip
    let title: String
    let context: StripContext
    let selection: String?
    /// The places a token can be moved to from its menu.
    let targets: (StripToken) -> [MoveTarget]
    let select: (StripToken) -> Void
    /// What is being dragged, while a drag of the editor is on.
    let dragging: EditorDrop?
    /// Where among its tokens this strip takes what is being dragged, for a pointer at a place: that place, or the nearest that lands
    /// (the line is drawn there, and it is dropped there). Nil when the model refuses the drop, or the strip can't take it anywhere.
    let landing: (EditorDrop, Int) -> Int?
    /// What the model refuses what is being dragged for, at a place: said by the banner.
    let refusal: (EditorDrop, Int) -> String?
    let refuse: @MainActor (String) -> Void
    /// A drag of this thing starts: what the drag carries.
    let drag: (EditorDrop) -> NSItemProvider
    /// What was dropped, and the place among this strip's tokens.
    let drop: @MainActor (EditorDrop, Int) -> Void
    let move: (StripToken, StripID) -> Void
    /// "Move Left" and "Move Right": whether the token has a place there that the strip doesn't decline, and the move.
    let canMoveWithin: (StripToken, LayoutEditorModel.Direction) -> Bool
    let moveWithin: (StripToken, LayoutEditorModel.Direction) -> Void
    let remove: (ItemID) -> Void

    /// Where the insertion line is while a drag is over the strip.
    @State private var insertion: Int?
    /// Whether the drag over the strip has had its refusal said: it is said once each time a drag enters the strip.
    @State private var refusalSaid = false
    /// How far the strip is scrolled.
    @State private var scrolled: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: LayoutEditorModel.tokenSpacing) {
                ForEach(strip.tokens, id: \.token.id) { layout in
                    TokenButton(layout: layout, strip: strip.id, context: context, isSelected: selection == layout.token.id,
                                targets: targets(layout.token), select: select, drag: drag, move: move,
                                canMoveWithin: canMoveWithin, moveWithin: moveWithin, remove: remove)
                }
            }
            .padding(.leading, LayoutEditorModel.stripPadding)
            .padding(.trailing, LayoutEditorModel.stripPadding)
            .frame(height: LayoutEditorModel.stripHeight)
            .overlay(alignment: .leading) { insertionLine }
            .overlay(alignment: .leading) {
                if strip.tokens.isEmpty {
                    Text(LayoutCopy.emptyStrip)
                        .foregroundStyle(.secondary)
                        .padding(.leading, LayoutEditorModel.stripPadding)
                        .allowsHitTesting(false)
                }
            }
        }
        .scrollIndicators(.automatic)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }, action: { _, offset in scrolled = offset })
        .frame(height: LayoutEditorModel.stripHeight)
        .onDrop(of: [LayoutDrag.type], delegate: StripDropDelegate(tokens: strip.tokens, scrolled: scrolled, dragging: dragging, landing: landing,
                                                                    refusal: refusal, refuse: refuse, refusalSaid: $refusalSaid,
                                                                    insertion: $insertion, perform: drop))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var insertionLine: some View {
        if let insertion {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 2, height: LayoutEditorModel.stripHeight - 12)
                .offset(x: LayoutEditorModel.insertionOffset(forIndex: insertion, in: strip.tokens) - 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The drop of a strip: where the pointer is says the place among the tokens, and the line is drawn at the place the drop lands, which is
/// the pointer's or the nearest one that does. Where the model refuses what is being dragged the drop is forbidden, and has no line; the
/// refusal is said once.
private struct StripDropDelegate: DropDelegate {
    let tokens: [StripTokenLayout]
    let scrolled: CGFloat
    let dragging: EditorDrop?
    let landing: (EditorDrop, Int) -> Int?
    let refusal: (EditorDrop, Int) -> String?
    let refuse: @MainActor (String) -> Void
    @Binding var refusalSaid: Bool
    @Binding var insertion: Int?
    let perform: @MainActor (EditorDrop, Int) -> Void

    private func place(_ info: DropInfo) -> Int {
        LayoutEditorModel.insertionIndex(atX: info.location.x + scrolled, in: tokens)
    }

    /// Where the line goes: where what is being dragged lands.
    private func accepted(_ info: DropInfo) -> Int? {
        guard let dragging else { return nil }
        return landing(dragging, place(info))
    }

    /// Says what the model refuses the drag for, the first time it is over a place that refuses it.
    private func sayRefusal(_ info: DropInfo) {
        guard !refusalSaid, let dragging, let text = refusal(dragging, place(info)) else { return }
        refusalSaid = true
        refuse(text)
    }

    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil && info.hasItemsConforming(to: [LayoutDrag.type])
    }

    func dropEntered(info: DropInfo) {
        insertion = accepted(info)
        sayRefusal(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        insertion = accepted(info)
        sayRefusal(info)
        return DropProposal(operation: insertion == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        insertion = nil
        refusalSaid = false
    }

    func performDrop(info: DropInfo) -> Bool {
        let place = accepted(info)
        insertion = nil
        refusalSaid = false
        guard let dragging, let place else { return false }
        perform(dragging, place)
        return true
    }
}

// MARK: Tokens

/// A token: a button that selects it and a drag source, with the menu that does what a drag does.
private struct TokenButton: View {
    let layout: StripTokenLayout
    let strip: StripID
    let context: StripContext
    let isSelected: Bool
    let targets: [MoveTarget]
    let select: (StripToken) -> Void
    let drag: (EditorDrop) -> NSItemProvider
    let move: (StripToken, StripID) -> Void
    let canMoveWithin: (StripToken, LayoutEditorModel.Direction) -> Bool
    let moveWithin: (StripToken, LayoutEditorModel.Direction) -> Void
    let remove: (ItemID) -> Void

    private var token: StripToken { layout.token }

    var body: some View {
        let sections = context.sections
        Button { select(token) } label: {
            TokenView(layout: layout, context: context, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .help(LayoutEditorModel.tooltip(of: token, names: context.names, sections: sections, cantReorder: context.cantReorder,
                                        rows: context.rows))
        .onDrag({ drag(.token(token, from: strip)) }, preview: {
            TokenView(layout: layout, context: context, isSelected: false)
        })
        .contextMenu {
            Button(LayoutCopy.moveLeft) { moveWithin(token, .left) }
                .disabled(!canMoveWithin(token, .left))
            Button(LayoutCopy.moveRight) { moveWithin(token, .right) }
                .disabled(!canMoveWithin(token, .right))
            if !targets.isEmpty {
                Menu(LayoutCopy.moveTo) {
                    ForEach(targets) { target in
                        Button(target.title) { move(token, target.strip) }
                    }
                }
            }
            if let item = ownItem {
                Button(LayoutCopy.remove, role: .destructive) { remove(item) }
            }
        }
        // The label is the button's own: its picture and marks are what it looks like, not what it is called.
        .accessibilityLabel(LayoutEditorModel.accessibilityLabel(of: token, names: context.names, sections: sections,
                                                                  cantReorder: context.cantReorder, rows: context.rows))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityActions {
            if canMoveWithin(token, .left) { Button(LayoutCopy.moveLeft) { moveWithin(token, .left) } }
            if canMoveWithin(token, .right) { Button(LayoutCopy.moveRight) { moveWithin(token, .right) } }
            ForEach(targets) { target in
                Button("\(LayoutCopy.moveTo) \(target.title)") { move(token, target.strip) }
            }
            if let item = ownItem {
                Button(LayoutCopy.remove) { remove(item) }
            }
        }
    }

    /// The spacer or group icon a token is, which can be removed.
    private var ownItem: ItemID? {
        if case .own(let item) = token { item } else { nil }
    }
}

/// What a token looks like: 28 points tall and as wide as its layout says, its pictures centred in their cells.
private struct TokenView: View {
    let layout: StripTokenLayout
    let context: StripContext
    let isSelected: Bool

    var body: some View {
        picture
            .frame(width: layout.width, height: LayoutEditorModel.tokenHeight)
            .background {
                if layout.token != .marker { RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)) }
            }
            .overlay {
                // The selection is a stroke in the accent colour, never a focus ring.
                if isSelected { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2) }
            }
            .overlay(alignment: .bottomTrailing) {
                if let bundleID = layout.token.bundleID, context.cantReorder.contains(bundleID) {
                    // A quiet mark: the icon's place isn't Mantel's to set.
                    Image(systemName: "pin.slash")
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let bundleID = layout.token.bundleID, context.rows[bundleID]?.needsAttention == true {
                    // A quiet mark too: something is the matter with the app's icon (the tooltip and the selected icon say what).
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var picture: some View {
        switch layout.token {
        case .app(_, let items):
            let cells = LayoutEditorModel.cellWidths(of: items, widths: context.widths)
            HStack(spacing: LayoutEditorModel.tokenGap) {
                ForEach(Array(items.enumerated()), id: \.offset) { place, item in
                    // At its own size, centred, and scaled down only to fit the cell.
                    let image = context.images.image(for: item, appearance: context.appearance)
                    let size = LayoutEditorModel.fittedSize(image.size, in: CGSize(width: cells[place], height: 24))
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                        .frame(width: cells[place], height: LayoutEditorModel.tokenHeight)
                }
            }
        case .own:
            if let group = LayoutEditorModel.group(of: layout.token, in: context.sections) {
                OwnPicture.group(group.look, folder: context.ownImages, side: 20)
            } else if let spacer = LayoutEditorModel.spacer(of: layout.token, in: context.sections) {
                SpacerPicture(label: spacer.label)
            } else {
                Image(systemName: LayoutCopy.paletteSymbol(.spacer)).foregroundStyle(.secondary)
            }
        case .marker:
            Capsule()
                .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                .frame(width: LayoutEditorModel.markerSize.width, height: LayoutEditorModel.markerSize.height)
        }
    }
}

/// A spacer in a strip: a dashed outline with its label, or the arrows that say it is a gap.
private struct SpacerPicture: View {
    let label: OwnItemLabel?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            switch label {
            case .text(let text), .emoji(let text):
                Text(text).font(.caption).lineLimit(1).padding(.horizontal, 4)
            case .symbol(let name):
                Image(systemName: name).font(.caption)
            case nil:
                Image(systemName: LayoutCopy.paletteSymbol(.spacer)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(4)
    }
}

/// What a group's icon looks like, for the editor.
enum OwnPicture {
    @ViewBuilder
    static func group(_ look: GroupLook, folder: URL, side: CGFloat) -> some View {
        switch look {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: side * 0.8))
        case .emoji(let text):
            Text(text).font(.system(size: side * 0.8))
        case .image(let fileName):
            if let image = NSImage(contentsOf: folder.appending(path: fileName)) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: side, height: side)
            } else {
                Image(systemName: GroupLook.standard.symbolName).font(.system(size: side * 0.8))
            }
        }
    }
}

extension GroupLook {
    /// The name of the symbol the standard look is.
    fileprivate var symbolName: String {
        if case .symbol(let name) = self { name } else { "square.grid.2x2" }
    }
}
