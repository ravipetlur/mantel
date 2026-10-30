import AppKit
import MKCore
import MKLayout

/// Mantel's spacers, groups and divider as real status items, kept as the layout model and `OwnItemsShown` say. (The dots are
/// `DotsController`'s.)
///
/// - **Made in the layout's order:** the sections' lists in order (a spacer or a group's icon as the list has it), then any group the
///   lists don't hold, each with the autosave name `OwnItems` gives it, so a place the person gave one by ⌘-dragging is kept by the system.
///   An item whose spacer or group is taken out of the layout is taken off the bar for good.
/// - **A spacer** is as wide as it is told (`length`), draws its label (a word or an emoji as the title, a symbol as a template image)
///   or nothing, and has no action. **A group** is as wide as its look, which is a symbol (template), an emoji, or a picture as given,
///   and its title if it has one; a click with either button toggles the group's panel, and the panel takes the keyboard (it is a click).
///   **The divider** is the thin line, 9 points wide.
/// - **On the bar or off it** is only what `OwnItemHiding` says (`isVisible`, or no length with the button hidden). It is never a change
///   to the layout: nothing here calls the layout API, so an item coming and going with a reveal never writes the order table. The
///   layout changes (an item added, taken out, resized, re-looked) are made by the person in the editor, which asks the session.
/// - **What the items say to the accessibility tools** is `OwnItems`' fixed words (a spacer's, the divider's, a group's with its title):
///   a style or a title changes what is drawn and never those words, since the menu bar's own tree has nothing else to tell an item by.
final class OwnItemsController: NSObject {
    /// The divider's width, in points.
    static let dividerLength: CGFloat = 9
    private static let imageBox = NSSize(width: 18, height: 18)

    /// What a group's icon was last drawn as.
    private struct GroupDrawn: Equatable {
        let look: GroupLook
        let title: String?
    }

    /// A click on a group's icon, with either button: toggles the group's panel. Set once, by whoever owns the panels.
    var groupClicked: (GroupID) -> Void = { _ in }
    private let imageFolder: URL
    private let hiding: OwnItemHiding
    private var spacerItems: [SpacerID: NSStatusItem] = [:]
    private var groupItems: [GroupID: NSStatusItem] = [:]
    private var dividerItem: NSStatusItem?
    /// What each item was last drawn as, so that only a change is drawn again.
    private var spacerDrawn: [SpacerID: LayoutSpacer] = [:]
    private var groupDrawn: [GroupID: GroupDrawn] = [:]
    /// The group each button belongs to.
    private var groupOfButton: [ObjectIdentifier: GroupID] = [:]
    private var loggedMissingLook = false

    /// - Parameters:
    ///   - imageFolder: where the pictures chosen for groups are (`MantelPaths.ownImages`).
    ///   - hiding: how an item is taken off the bar.
    init(imageFolder: URL, hiding: OwnItemHiding = .current) {
        self.imageFolder = imageFolder
        self.hiding = hiding
        super.init()
    }

    /// Where Mantel's own spacers', groups' and divider's buttons are, in AppKit's global points, by the name the system keeps each one's
    /// place under. An item that is off the bar isn't listed.
    func buttonFrames() -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        for (id, item) in spacerItems where isOnBar(item) {
            if let name = autosaveName(spacer: id) { frames[name] = item.button?.window?.frame }
        }
        for (id, item) in groupItems where isOnBar(item) {
            if let name = autosaveName(group: id) { frames[name] = item.button?.window?.frame }
        }
        if let dividerItem, isOnBar(dividerItem) { frames[OwnItems.dividerName] = dividerItem.button?.window?.frame }
        return frames
    }

    /// Whether the item is on the bar by the way this build takes items off it.
    private func isOnBar(_ item: NSStatusItem) -> Bool {
        switch hiding {
        case .visibility: item.isVisible
        case .zeroLength: item.length > 0 && item.button?.isHidden == false
        }
    }

    // MARK: Keeping the items

    /// Makes, changes and takes away the items for the layout, and puts each on the bar or off it as `shown` says.
    func update(sections: SectionModel?, shown: OwnItemsShown) {
        let sections = sections ?? SectionModel()
        remove(missingFrom: sections)
        for item in OwnItemsVisibility.creationOrder(sections) {
            switch item {
            case .spacer(let id):
                guard let spacer = sections.spacers[id] else { continue }
                keep(spacer: spacer, onBar: shown.spacers.contains(id))
            case .group(let id):
                guard let group = sections.groups[id] else { continue }
                keep(group: group, onBar: shown.groups.contains(id))
            }
        }
        keepDivider(onBar: shown.divider)
    }

    private func remove(missingFrom sections: SectionModel) {
        for (id, item) in spacerItems where sections.spacers[id] == nil {
            NSStatusBar.system.removeStatusItem(item)
            spacerItems[id] = nil
            spacerDrawn[id] = nil
        }
        for (id, item) in groupItems where sections.groups[id] == nil {
            if let button = item.button { groupOfButton[ObjectIdentifier(button)] = nil }
            NSStatusBar.system.removeStatusItem(item)
            groupItems[id] = nil
            groupDrawn[id] = nil
        }
    }

    /// The name an item keeps its place under, or nil for an id `OwnItems` refuses (one the wide spacer's invisible items go by): such an
    /// item is never made, for it would share its place and visibility with that one's.
    private func autosaveName(spacer id: SpacerID) -> String? {
        OwnItems.autosaveName(of: OwnItems.itemID(id))
    }

    private func autosaveName(group id: GroupID) -> String? {
        OwnItems.autosaveName(of: OwnItems.itemID(id))
    }

    // MARK: Spacers

    private func keep(spacer: LayoutSpacer, onBar: Bool) {
        guard let item = spacerItems[spacer.id] ?? makeSpacerItem(spacer) else { return }
        if spacerDrawn[spacer.id] == nil || spacerDrawn[spacer.id]?.label != spacer.label {
            drawLabel(spacer.label, on: item)
        }
        spacerDrawn[spacer.id] = spacer
        place(item, onBar: onBar, length: CGFloat(spacer.width))
    }

    private func makeSpacerItem(_ spacer: LayoutSpacer) -> NSStatusItem? {
        guard let name = autosaveName(spacer: spacer.id) else { return nil }
        let item = NSStatusBar.system.statusItem(withLength: CGFloat(spacer.width))
        item.autosaveName = name
        item.menu = nil
        // No action: a click on a spacer does nothing.
        item.button?.target = nil
        item.button?.action = nil
        item.button?.setAccessibilityIdentifier(name)
        item.button?.setAccessibilityLabel(OwnItems.spacerDescription)
        spacerItems[spacer.id] = item
        return item
    }

    private func drawLabel(_ label: OwnItemLabel?, on item: NSStatusItem) {
        guard let button = item.button else { return }
        button.title = ""
        button.image = nil
        button.imagePosition = .noImage
        switch label {
        case .text(let text), .emoji(let text):
            button.title = text
        case .symbol(let name):
            if let image = symbolImage(name, description: OwnItems.spacerDescription) {
                button.image = image
                button.imagePosition = .imageOnly
            } else {
                // A symbol that isn't one: the spacer still keeps its place, as one with no label does.
                button.image = LiveSpacers.emptyImage
                button.imagePosition = .imageOnly
                noteMissingLook()
            }
        case nil:
            // No text and no picture: the same empty template image the wide spacer's items have, so that the button has a place of its
            // own on the bar and an accessibility element to be read by.
            button.image = LiveSpacers.emptyImage
            button.imagePosition = .imageOnly
        }
    }

    // MARK: Groups

    private func keep(group: IconGroup, onBar: Bool) {
        guard let item = groupItems[group.id] ?? makeGroupItem(group) else { return }
        let drawn = GroupDrawn(look: group.look, title: group.title)
        if groupDrawn[group.id] != drawn {
            groupDrawn[group.id] = drawn
            draw(group: group, on: item)
        }
        place(item, onBar: onBar, length: NSStatusItem.variableLength)
    }

    private func makeGroupItem(_ group: IconGroup) -> NSStatusItem? {
        guard let name = autosaveName(group: group.id) else { return nil }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = name
        item.menu = nil
        if let button = item.button {
            button.setAccessibilityIdentifier(name)
            button.target = self
            button.action = #selector(groupClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            groupOfButton[ObjectIdentifier(button)] = group.id
        }
        groupItems[group.id] = item
        return item
    }

    /// Draws the group's look and title, and says what it is to the accessibility tools: its title and “group” (`OwnItems`), whatever it
    /// looks like.
    private func draw(group: IconGroup, on item: NSStatusItem) {
        guard let button = item.button else { return }
        let description = OwnItems.groupDescription(title: group.title)
        let title = group.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var image: NSImage?
        var text = ""
        switch group.look {
        case .symbol(let name): image = symbolImage(name, description: description)
        case .emoji(let emoji): text = emoji
        case .image(let fileName): image = picture(fileName, description: description)
        }
        if image == nil, text.isEmpty {
            // A symbol that isn't one, or a picture whose file is gone: the group still has an icon to click.
            noteMissingLook()
            if case .symbol(let name) = GroupLook.standard { image = symbolImage(name, description: description) }
        }
        if !title.isEmpty { text = text.isEmpty ? title : "\(text) \(title)" }
        button.image = image
        button.title = text
        button.imagePosition = switch (image != nil, !text.isEmpty) {
        case (true, true): .imageLeading
        case (true, false): .imageOnly
        case (false, _): .noImage
        }
        button.setAccessibilityLabel(description)
    }

    @objc private func groupClicked(_ sender: NSStatusBarButton) {
        guard let group = groupOfButton[ObjectIdentifier(sender)] else { return }
        groupClicked(group)
    }

    // MARK: The divider

    private func keepDivider(onBar: Bool) {
        let item = dividerItem ?? makeDividerItem()
        place(item, onBar: onBar, length: Self.dividerLength)
    }

    private func makeDividerItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: Self.dividerLength)
        item.autosaveName = OwnItems.dividerName
        item.menu = nil
        if let button = item.button {
            button.setAccessibilityIdentifier(OwnItems.dividerName)
            button.setAccessibilityLabel(OwnItems.dividerDescription)
            let line = (LiveSpacers.lineImage.copy() as? NSImage) ?? LiveSpacers.lineImage
            line.isTemplate = true
            line.accessibilityDescription = OwnItems.dividerDescription
            button.image = line
            button.imagePosition = .imageOnly
        }
        dividerItem = item
        return item
    }

    // MARK: On the bar or off it

    /// Puts an item on the bar or takes it off, the way `OwnItemHiding` says: only what is different from how the item is now is set.
    private func place(_ item: NSStatusItem, onBar: Bool, length onBarLength: CGFloat) {
        let presentation = hiding.presentation(onBar: onBar)
        if item.isVisible != presentation.isVisible { item.isVisible = presentation.isVisible }
        let length = presentation.isCollapsed ? 0 : onBarLength
        if item.length != length { item.length = length }
        if let button = item.button, button.isHidden != presentation.isCollapsed { button.isHidden = presentation.isCollapsed }
    }

    // MARK: Pictures

    private func symbolImage(_ name: String, description: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: description)?.withSymbolConfiguration(configuration) else {
            return nil
        }
        symbol.isTemplate = true
        symbol.accessibilityDescription = description
        return symbol
    }

    /// A picture the person chose, drawn as it is (not a template), brought down to fit when it is bigger than the box.
    private func picture(_ fileName: String, description: String) -> NSImage? {
        guard fileName == (fileName as NSString).lastPathComponent,
              let picture = NSImage(contentsOf: imageFolder.appending(path: fileName, directoryHint: .notDirectory)),
              picture.size.width > 0, picture.size.height > 0 else { return nil }
        let factor = min(Self.imageBox.width / picture.size.width, Self.imageBox.height / picture.size.height, 1)
        picture.size = NSSize(width: picture.size.width * factor, height: picture.size.height * factor)
        picture.isTemplate = false
        picture.accessibilityDescription = description
        return picture
    }

    private func noteMissingLook() {
        guard !loggedMissingLook else { return }
        loggedMissingLook = true
        Log.warning("own-items", "an own item's symbol or picture couldn't be loaded, so a standard one is drawn")
    }
}
