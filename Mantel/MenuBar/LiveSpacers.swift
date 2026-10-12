import AppKit
import MKMenuBar

/// The invisible status items the wide-spacer engine uses to push icons off the menu bar: the divider, `mantel.spacer.divider` (and
/// `mantel.spacer.divider.2`, `.3` and so on when a wide display needs more than one to cover it), and `mantel.spacer.always`.
///
/// They exist only while the engine is in use. The engine shows widths: an empty divider means it was torn down, and every item is
/// taken off the bar; any other widths make the items there are as many as they say, each as wide as its width (0 is an item that is
/// there and takes no room). They have no menu and nothing to click. The ones that hide draw nothing (an empty image); the divider
/// that takes no room draws a thin line, so that the person can see where to ⌘-drag icons (`SpacerWidths.dividerItems` says which).
@MainActor
final class LiveSpacers: SpacerControlling {
    static let dividerName = "mantel.spacer.divider"
    static let alwaysName = "mantel.spacer.always"

    /// What the system keeps the place of the divider's `index`th item in the menu bar under: the first is `mantel.spacer.divider`, the
    /// next ones `mantel.spacer.divider.2`, `mantel.spacer.divider.3`.
    static func dividerName(at index: Int) -> String {
        index == 0 ? dividerName : "\(dividerName).\(index + 1)"
    }

    private var dividers: [NSStatusItem] = []
    private var always: NSStatusItem?

    /// A picture of nothing: the item has an image, so that it has a button and a place, and nothing is drawn in it.
    private static let emptyImage: NSImage = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.isTemplate = true
        return image
    }()

    /// The divider's line while it takes no room: 1 point by 14, a template, so that the menu bar colours it.
    private static let lineImage: NSImage = {
        let image = NSImage(size: NSSize(width: 1, height: 14), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    func show(widths: SpacerWidths) {
        guard !widths.divider.isEmpty else {
            removeAll()
            return
        }
        while dividers.count < widths.divider.count {
            dividers.append(makeItem(named: Self.dividerName(at: dividers.count)))
        }
        while dividers.count > widths.divider.count, let last = dividers.popLast() {
            NSStatusBar.system.removeStatusItem(last)
        }
        for (item, look) in zip(dividers, widths.dividerItems) {
            item.length = max(look.length, 0)
            item.button?.image = look.drawsLine ? Self.lineImage : Self.emptyImage
        }
        let item = always ?? makeItem(named: Self.alwaysName)
        always = item
        item.length = max(widths.always, 0)
    }

    private func makeItem(named name: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: 0)
        item.autosaveName = name
        item.button?.image = Self.emptyImage
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleNone
        item.menu = nil
        return item
    }

    private func removeAll() {
        for item in dividers { NSStatusBar.system.removeStatusItem(item) }
        dividers = []
        if let always { NSStatusBar.system.removeStatusItem(always) }
        always = nil
    }
}
