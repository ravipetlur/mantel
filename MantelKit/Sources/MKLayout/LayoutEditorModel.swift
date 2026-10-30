import CoreGraphics
import MKCore

// What the layout editor's strips hold, and what dropping on one does. The views draw the strips and hand the drops here; every decision
// is made in this file.

/// One strip of the layout editor: a section's, or a group's.
public enum StripID: Hashable, Sendable {
    case section(MenuBarSection)
    case group(GroupID)
}

/// One thing in a strip that can be dragged and selected.
public enum StripToken: Hashable, Sendable, Identifiable {
    /// An app, with every icon it draws: they are one token, drawn together.
    case app(bundleID: String, items: [ItemID])
    /// A spacer or a group's icon.
    case own(ItemID)
    /// Where new icons are put.
    case marker

    public var id: String {
        switch self {
        case .app(let bundleID, _): "app:\(bundleID)"
        case .own(let item): "own:\(item.string)"
        case .marker: "marker"
        }
    }

    /// The icon that stands for the token when it is dropped: an app's first icon (the whole app moves with it), or the own item.
    public var item: ItemID? {
        switch self {
        case .app(_, let items): items.first
        case .own(let item): item
        case .marker: nil
        }
    }

    /// The bundle ID of the app a token is, nil for any other.
    public var bundleID: String? {
        if case .app(let bundleID, _) = self { bundleID } else { nil }
    }
}

/// A token and how wide it is drawn (the width of the slots of its icons, P45).
public struct StripTokenLayout: Sendable, Equatable {
    public let token: StripToken
    public let width: CGFloat

    public init(token: StripToken, width: CGFloat) {
        self.token = token
        self.width = width
    }
}

public struct Strip: Sendable, Equatable {
    public let id: StripID
    /// Left to right.
    public let tokens: [StripTokenLayout]

    public init(id: StripID, tokens: [StripTokenLayout]) {
        self.id = id
        self.tokens = tokens
    }
}

/// What the layout editor offers to add to the menu bar.
public enum PaletteItem: String, Sendable, CaseIterable {
    case spacer, group, marker
}

/// What was dropped on a strip.
public enum EditorDrop: Sendable, Equatable {
    /// A token of a strip, from that strip.
    case token(StripToken, from: StripID)
    /// A system icon. It is never a token of a strip (P40), and a drop of one is refused as a guard.
    case system(ItemID)
    case palette(PaletteItem)
}

/// What a drop does.
public enum EditorOperation: Sendable, Equatable {
    /// An icon (an app's, with the whole app, or an own item) put at a place in a section's list.
    case insert(ItemID, MenuBarSection, Int)
    /// An app put in a group at a place among its members.
    case moveToGroup(bundleID: String, GroupID, Int)
    case addSpacer(MenuBarSection, Int)
    case addGroup(MenuBarSection, Int)
    /// The marker for new icons put in a section's list.
    case marker(MenuBarSection, Int)
    case noChange
    /// Nothing is done, and this is what to tell the person.
    case refused(String)
}

/// Where a drop lands, said by the tokens it lands between instead of by a number: a number is a place in the list as one model has it,
/// and the model the session applies a change to may not be the one the drop was worked out on (a change still being made, a read that
/// listed a new app). The place is worked out again, from these, on the session's model when the change runs.
public struct DropAnchors: Sendable, Equatable {
    /// The token just left of the place (`StripToken.id`); nil is the start of the strip.
    public var left: String?
    /// The token just right of the place; nil is the end of the strip.
    public var right: String?

    public init(left: String?, right: String?) {
        self.left = left
        self.right = right
    }
}

/// A spacer or a group a palette drop makes. It is made where the drop is, so that its ID is known to the strips (which show it at once)
/// and to the session (which puts that one in the layout).
public enum NewOwnItem: Sendable, Equatable {
    case spacer(LayoutSpacer)
    case group(IconGroup)
}

/// A drop, a "Move to", "Move Left"/"Move Right" or an "Add" as it is sent to the session: what was dropped, on which strip, between
/// which tokens, and what the person's Mac allowed when it was dropped.
public struct DropRequest: Sendable, Equatable {
    public var drop: EditorDrop
    public var strip: StripID
    public var between: DropAnchors
    /// For a palette spacer or group: the one to add.
    public var created: NewOwnItem?
    public var canReorder: Bool
    public var cantReorder: Set<String>
    /// The apps that were running when it was dropped, as the strips were made from them (nil: every app counts as running).
    public var running: Set<String>?
    /// The records the strips left out, as they were made (`SectionModel.staleRecords`).
    public var stale: StaleRecords

    public init(drop: EditorDrop, strip: StripID, between: DropAnchors, created: NewOwnItem? = nil, canReorder: Bool,
                cantReorder: Set<String> = [], running: Set<String>? = nil, stale: StaleRecords = .none) {
        self.drop = drop
        self.strip = strip
        self.between = between
        self.created = created
        self.canReorder = canReorder
        self.cantReorder = cantReorder
        self.running = running
        self.stale = stale
    }
}

public enum LayoutEditorModel {
    /// The gap between an app's icons inside one token.
    public static let tokenGap: CGFloat = 4
    /// How wide the marker's token is: the width of its capsule.
    public static let markerWidth: CGFloat = 12

    // MARK: The strips

    /// The strips, in the order the editor lists them: Shown, Hidden, Always Hidden, then one for each group in the group order.
    ///
    /// - **Apps:** an app's icons are one token, at the place of its first icon in the list. Only the apps that are running have one.
    ///   The icons of an app in the section that the model's list doesn't hold yet come after the listed ones, by app.
    /// - **Never a system icon** (P40), and never a dot or the divider.
    /// - **The marker** is in the strip of the section new icons go to, before the icon `newItemsIndex` names, or last when there is none.
    /// - **A group's strip** holds the apps of the group in the order of its members.
    /// - **Widths** are each icon's slot width as `ItemWidthCache` last saw it, from 30 to 120 points (`SecondBarGeometry.cellWidth`); an app's
    ///   token is its icons' widths with `tokenGap` between them. A spacer is as wide as it is, within the same limits.
    public static func strips(sections: SectionModel, inventory: Inventory, running: Set<String>, widths: ItemWidthCache,
                              stale: StaleRecords = .none) -> [Strip] {
        let ids: [StripID] = MenuBarSection.allCases.map(StripID.section) + groupOrder(of: sections).map(StripID.group)
        return ids.map {
            Strip(id: $0, tokens: tokens(of: $0, sections: sections, inventory: inventory, running: running, stale: stale, widths: widths))
        }
    }

    /// The groups in the order the editor lists them: `groupOrder`, then any other the model has.
    public static func groupOrder(of sections: SectionModel) -> [GroupID] {
        let others = sections.groups.keys.filter { !sections.groupOrder.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        return sections.groupOrder.filter { sections.groups[$0] != nil } + others
    }

    private static func tokens(of strip: StripID, sections: SectionModel, inventory: Inventory, running: Set<String>?,
                               stale: StaleRecords, widths: ItemWidthCache) -> [StripTokenLayout] {
        let tokens = rawTokens(of: strip, sections: sections, inventory: inventory, running: running, stale: stale)
        return tokens.map { StripTokenLayout(token: $0, width: width(of: $0, sections: sections, widths: widths)) }
    }

    /// The tokens of a strip without their widths. With `running` nil every app counts as running.
    private static func rawTokens(of strip: StripID, sections: SectionModel, inventory: Inventory, running: Set<String>?,
                                  stale: StaleRecords) -> [StripToken] {
        let isRunning: (String) -> Bool = { running?.contains($0) ?? true }
        let inInventory = Dictionary(inventory.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let isAnApp: (ItemID) -> Bool = { id in
            !id.isSystem && id.bundleID != OwnItems.owner && inInventory[id]?.isMantel != true && inInventory[id]?.ownKind == nil
        }

        switch strip {
        case .section(let section):
            let listed = sections.items(in: section)
            let listedSet = Set(listed)
            let allListed = allListedItems(sections)
            // The icons of apps in this section that no list holds yet: after the listed ones, by app.
            let unlisted = inventory.items.map(\.id).filter { id in
                isAnApp(id) && !allListed.contains(id) && sections.section(ofApp: id.bundleID) == section
                    && sections.apps[id.bundleID]?.group == nil && !stale.contains(id)
            }
            var built: [(token: StripToken, start: Int)] = []
            var slots: [String: Int] = [:]
            func add(_ id: ItemID, at place: Int) {
                // A spacer or a group's icon: never a dot or the divider.
                if OwnItems.spacerID(of: id) != nil || OwnItems.groupID(of: id) != nil {
                    built.append((.own(id), place))
                    return
                }
                guard isAnApp(id), isRunning(id.bundleID), !stale.contains(id) else { return }
                if let slot = slots[id.bundleID], case .app(let bundleID, let items) = built[slot].token {
                    if !items.contains(id) { built[slot].token = .app(bundleID: bundleID, items: items + [id]) }
                } else {
                    slots[id.bundleID] = built.count
                    built.append((.app(bundleID: id.bundleID, items: [id]), place))
                }
            }
            for (place, id) in listed.enumerated() { add(id, at: place) }
            var out = built.map(\.token)
            if section == sections.newItems {
                // Before the first token that starts at the marker's place or after it; after every listed token otherwise.
                let at = sections.newItemsIndex.flatMap { index in built.firstIndex { $0.start >= index } } ?? built.count
                out.insert(.marker, at: at)
            }
            // Unlisted apps follow (the marker, when it is last, comes before them: a new app is put there).
            var more: [String: Int] = [:]
            for id in unlisted where !listedSet.contains(id) && isRunning(id.bundleID) {
                if let slot = more[id.bundleID], case .app(let bundleID, let items) = out[slot] {
                    out[slot] = .app(bundleID: bundleID, items: items + [id])
                } else if let slot = out.firstIndex(where: { $0.bundleID == id.bundleID }), case .app(let bundleID, let items) = out[slot] {
                    out[slot] = .app(bundleID: bundleID, items: items + [id])
                } else {
                    more[id.bundleID] = out.count
                    out.append(.app(bundleID: id.bundleID, items: [id]))
                }
            }
            return out
        case .group(let group):
            let members = sections.groups[group]?.members ?? []
            let held = sections.groupItems[group] ?? []
            var tokens: [StripToken] = []
            var seen: Set<String> = []
            for member in members + held.map(\.bundleID) where seen.insert(member).inserted && isRunning(member) {
                var items = held.filter { $0.bundleID == member && !stale.contains($0) }
                if items.isEmpty { items = inventory.items.map(\.id).filter { $0.bundleID == member && isAnApp($0) && !stale.contains($0) } }
                if !items.isEmpty { tokens.append(.app(bundleID: member, items: items)) }
            }
            return tokens
        }
    }

    private static func allListedItems(_ sections: SectionModel) -> Set<ItemID> {
        Set(MenuBarSection.allCases.flatMap { sections.order[$0] ?? [] } + sections.groupItems.values.flatMap { $0 })
    }

    private static func width(of token: StripToken, sections: SectionModel, widths: ItemWidthCache) -> CGFloat {
        switch token {
        case .app(_, let items):
            let cells = cellWidths(of: items, widths: widths)
            return cells.reduce(0, +) + tokenGap * CGFloat(max(cells.count - 1, 0))
        case .own(let item):
            if let spacer = OwnItems.spacerID(of: item).flatMap({ sections.spacers[$0] }) {
                return SecondBarGeometry.cellWidth(slotWidth: CGFloat(spacer.width))
            }
            return SecondBarGeometry.cellWidth(slotWidth: nil)
        case .marker:
            return markerWidth
        }
    }

    /// How wide each icon of an app's token is drawn: its slot width within 30 to 120 points.
    public static func cellWidths(of items: [ItemID], widths: ItemWidthCache) -> [CGFloat] {
        items.map { SecondBarGeometry.cellWidth(slotWidth: widths.slotWidth(of: $0)) }
    }

    // MARK: Geometry

    /// How tall a strip is, and a token in it.
    public static let stripHeight: CGFloat = 44
    public static let tokenHeight: CGFloat = 28
    /// The marker's capsule.
    public static let markerSize = CGSize(width: 12, height: 22)
    /// The room at the start of a strip, and between its tokens.
    public static let stripPadding: CGFloat = 8
    public static let tokenSpacing: CGFloat = 4

    /// Where a token starts along a strip's content.
    private static func start(ofToken index: Int, in tokens: [StripTokenLayout]) -> CGFloat {
        stripPadding + tokens.prefix(index).reduce(0) { $0 + $1.width + tokenSpacing }
    }

    /// The place among a strip's tokens that a drop at `x` (along the strip's content) is: before the first token whose middle is past `x`,
    /// or after the last.
    public static func insertionIndex(atX x: CGFloat, in tokens: [StripTokenLayout]) -> Int {
        for (index, layout) in tokens.enumerated() where x < start(ofToken: index, in: tokens) + layout.width / 2 {
            return index
        }
        return tokens.count
    }

    /// Where the insertion line is drawn for a place among the tokens: in the gap before the token (or after the last), along the content.
    public static func insertionOffset(forIndex index: Int, in tokens: [StripTokenLayout]) -> CGFloat {
        if index <= 0 { return stripPadding / 2 }
        return start(ofToken: min(index, tokens.count), in: tokens) - tokenSpacing / 2
    }

    /// The size a picture is drawn at: its own size, scaled down (never up) to fit the room.
    public static func fittedSize(_ size: CGSize, in room: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(1, room.width / size.width, room.height / size.height)
        return CGSize(width: size.width * max(scale, 0), height: size.height * max(scale, 0))
    }

    // MARK: Words

    /// The spacer an own token is, or nil for any other.
    public static func spacer(of token: StripToken, in sections: SectionModel) -> LayoutSpacer? {
        guard case .own(let item) = token, let id = OwnItems.spacerID(of: item) else { return nil }
        return sections.spacers[id]
    }

    /// The group an own token is the icon of, or nil for any other.
    public static func group(of token: StripToken, in sections: SectionModel) -> IconGroup? {
        guard case .own(let item) = token, let id = OwnItems.groupID(of: item) else { return nil }
        return sections.groups[id]
    }

    /// A group's name in the editor: its title, or "Group" (with its place among the groups when there are several without a title).
    public static func groupTitle(_ group: GroupID, in sections: SectionModel) -> String {
        let title = sections.groups[group]?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty { return title }
        let untitled = groupOrder(of: sections).filter {
            (sections.groups[$0]?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        }
        guard untitled.count > 1, let place = untitled.firstIndex(of: group) else { return LayoutCopy.paletteGroup }
        return "\(LayoutCopy.paletteGroup) \(place + 1)"
    }

    /// What a token is called: an app by its name (`names`, else its bundle ID), a spacer "Spacer", a group by its title, the marker by
    /// the palette's words for it.
    public static func title(of token: StripToken, names: [String: String], sections: SectionModel) -> String {
        switch token {
        case .app(let bundleID, _):
            return names[bundleID] ?? bundleID
        case .own(let item):
            if let group = OwnItems.groupID(of: item) { return groupTitle(group, in: sections) }
            return LayoutCopy.paletteSpacer
        case .marker:
            return LayoutCopy.paletteMarker
        }
    }

    /// What the tooltip of a token says, one line each: its title; for an app, what is the matter with its icons (`AppRow.helpText`: not
    /// answering, turned off in System Settings, or macOS's not tying the icon to it); that Mantel moved it here (`LayoutCopy.autoHelp`);
    /// and that it can't be reordered.
    public static func tooltip(of token: StripToken, names: [String: String], sections: SectionModel, cantReorder: Set<String>,
                               rows: [String: AppRow] = [:]) -> String {
        var lines = [title(of: token, names: names, sections: sections)]
        guard let bundleID = token.bundleID else { return lines[0] }
        if let help = rows[bundleID]?.helpText, !help.isEmpty { lines.append(help) }
        if sections.apps[bundleID]?.isAuto == true { lines.append(LayoutCopy.autoHelp) }
        if cantReorder.contains(bundleID) { lines.append(LayoutCopy.cantReorderHelp) }
        return lines.joined(separator: "\n")
    }

    /// What the accessibility tools call a token: its title; for an app, what its row says when something is the matter
    /// (`AppRow.statusText` for one that isn't answering or is turned off, `AppRow.note` for an icon macOS doesn't tie to it), "Auto" when
    /// Mantel moved it, and "can't reorder" when it can't be.
    public static func accessibilityLabel(of token: StripToken, names: [String: String], sections: SectionModel,
                                          cantReorder: Set<String>, rows: [String: AppRow] = [:]) -> String {
        var parts = [title(of: token, names: names, sections: sections)]
        guard let bundleID = token.bundleID else { return parts[0] }
        if let row = rows[bundleID] {
            // What is the matter with the app's icons, in the words the tooltip has: not answering, or off in System Settings, or the note
            // that macOS doesn't tie its icon to it. Never the count: it says nothing is wrong.
            if row.isNotAnswering || row.isTurnedOff { parts.append(row.statusText) } else if let note = row.note { parts.append(note) }
        }
        if sections.apps[bundleID]?.isAuto == true { parts.append(LayoutCopy.auto) }
        if cantReorder.contains(bundleID) { parts.append(LayoutCopy.cantReorderLabel) }
        return parts.joined(separator: ", ")
    }

    // MARK: Drops

    /// What a drop is decided from: the model as the strips were made from it, and what the writer and the apps allow.
    public struct DropContext: Sendable {
        public var sections: SectionModel
        /// Whether the order can be written. Without it a token can't be reordered within its strip (the marker can: it moves no icon), and
        /// a palette item lands at the end of the section whatever the place (P14).
        public var canReorder: Bool
        /// The apps whose place macOS gives Mantel no way to set. They change section like any app, and can't be placed.
        public var cantReorder: Set<String>
        /// What `strips` was made from, so that a place is read among the tokens that are drawn. Left out, every app the model lists counts
        /// as running.
        public var inventory: Inventory
        public var running: Set<String>?
        /// The records the strips left out: icons that aren't there now have no token, and a drop counts them as it counts the icons of
        /// the apps that aren't running.
        public var stale: StaleRecords

        public init(sections: SectionModel, canReorder: Bool, cantReorder: Set<String> = [], inventory: Inventory = .empty,
                    running: Set<String>? = nil, stale: StaleRecords = .none) {
            self.sections = sections
            self.canReorder = canReorder
            self.cantReorder = cantReorder
            self.inventory = inventory
            self.running = running
            self.stale = stale
        }
    }

    /// What dropping something on a strip, at a place among its tokens, does.
    ///
    /// - Parameters:
    ///   - index: the place among the strip's tokens as they are drawn (0 is before the first; the count is after the last), counted
    ///     with the dragged token still in the strip, when it came from it.
    ///   - canReorder, cantReorder, inventory, running, stale: see `DropContext`.
    ///
    /// A system icon is refused (P40). A token dropped on its own place is no change. Between strips every drop is allowed.
    ///
    /// **A drop lands exactly where the strip shows it, or is declined** (`.noChange`). A place among the tokens
    /// is turned into a place in the section's list by the tokens beside it, never by counting icons: the list also holds system items and
    /// the icons of apps that aren't running, which have no token. Where that can't put the thing where the person dropped it (beside the
    /// marker, when the list can't tell its two sides apart; after an app no list holds yet, which is drawn after every listed one), the drop
    /// is declined. A group holds apps only: anything else dropped on its strip is declined. (The strips don't drop at a declined place:
    /// they snap to one that lands, `landingPlace`.)
    public static func operation(for drop: EditorDrop, onto strip: StripID, at index: Int, sections: SectionModel, canReorder: Bool,
                                 cantReorder: Set<String> = [], inventory: Inventory = .empty,
                                 running: Set<String>? = nil, stale: StaleRecords = .none) -> EditorOperation {
        operation(for: drop, onto: strip, at: index, in: DropContext(sections: sections, canReorder: canReorder, cantReorder: cantReorder,
                                                                     inventory: inventory, running: running, stale: stale))
    }

    public static func operation(for drop: EditorDrop, onto strip: StripID, at index: Int, in context: DropContext) -> EditorOperation {
        switch decide(drop, onto: strip, at: index, in: context) {
        case .done(let operation): operation
        case .declined: .noChange
        }
    }

    /// What the model refuses the drop for, near this place: the words to say, or nil when it isn't refused.
    public static func refusal(for drop: EditorDrop, onto strip: StripID, near index: Int, in context: DropContext) -> String? {
        if case .done(.refused(let text)) = decide(drop, onto: strip, at: index, in: context) { text } else { nil }
    }

    /// The place among a strip's tokens where a drop near `index` lands, which is where the insertion line is drawn and where it is dropped.
    ///
    /// - **Where it lands at `index`, that is it** (`operation` at that place is not `.noChange`, unless it is the token's own place).
    /// - **Where it can't** (a drop right of a marker that is last, or just right of a placed marker; after an app no list holds yet), the
    ///   nearest place to the left that does, else the nearest to the right.
    /// - **Without the file, a palette spacer or group** lands at the end of its section, and that is where the line is.
    /// - **Nil:** the model refuses the drop (the drag is forbidden), or the strip can't take it at any place (anything but an app on a
    ///   group's strip).
    public static func landingPlace(for drop: EditorDrop, onto strip: StripID, near index: Int, in context: DropContext) -> Int? {
        let count = rawTokens(of: strip, sections: context.sections, inventory: context.inventory, running: context.running, stale: context.stale).count
        let index = min(max(index, 0), count)
        switch decide(drop, onto: strip, at: index, in: context) {
        case .done(.refused):
            return nil
        case .done(let operation):
            if case .palette(let item) = drop, item != .marker, !context.canReorder {
                return shownPlace(of: operation, onto: strip, in: context)
            }
            return index
        case .declined:
            // A group holds apps only: nothing else lands anywhere on its strip.
            if case .group = strip {
                guard case .token(.app, _) = drop else { return nil }
            }
            func lands(_ place: Int) -> Bool {
                if case .done(let operation) = decide(drop, onto: strip, at: place, in: context), !operation.isRefused { true } else { false }
            }
            if let left = stride(from: index - 1, through: 0, by: -1).first(where: lands) { return left }
            return (index + 1 <= count) ? (index + 1...count).first(where: lands) : nil
        }
    }

    /// Where a palette spacer or group shows among the strip's tokens once it is added at the end of the section's list.
    private static func shownPlace(of operation: EditorOperation, onto strip: StripID, in context: DropContext) -> Int {
        let before = rawTokens(of: strip, sections: context.sections, inventory: context.inventory, running: context.running, stale: context.stale).map(\.id)
        var after = context.sections
        guard let made = perform(operation, created: nil, on: &after) else { return before.count }
        let shown = rawTokens(of: strip, sections: after, inventory: context.inventory, running: context.running, stale: context.stale).map(\.id)
        guard let place = shown.firstIndex(of: made) else { return before.count }
        let known = Set(before)
        return shown[..<place].filter(known.contains).count
    }

    /// The place a menu puts something at when it says "at the end" of a strip: after the last token, or the furthest place before it
    /// where the drop lands (the marker, when it is last, can't be passed by a drop that lands left of it).
    public static func endPlace(for drop: EditorDrop, onto strip: StripID, in context: DropContext) -> Int {
        let count = rawTokens(of: strip, sections: context.sections, inventory: context.inventory, running: context.running, stale: context.stale).count
        return landingPlace(for: drop, onto: strip, near: count, in: context) ?? count
    }

    public enum Direction: Sendable { case left, right }

    /// The place among a strip's tokens that moves a token to `direction` (counted with the token still in the strip, as a drop is): the
    /// first place that way that isn't its own and isn't declined, so a token can step past the marker; nil when there is none. A menu's
    /// "Move Left" and "Move Right" drop the token there. A refusal isn't a decline: the place is given, and the drop says why not.
    public static func neighbourPlace(of token: StripToken, toward direction: Direction, in strip: Strip, context: DropContext) -> Int? {
        guard let position = strip.tokens.firstIndex(where: { $0.token.id == token.id }) else { return nil }
        let places: [Int]
        switch direction {
        case .left: places = Array((0..<position).reversed())
        case .right: places = position + 2 <= strip.tokens.count ? Array((position + 2)...strip.tokens.count) : []
        }
        return places.first { place in
            switch decide(.token(token, from: strip.id), onto: strip.id, at: place, in: context) {
            case .declined, .done(.noChange): false
            case .done: true
            }
        }
    }

    // MARK: A drop as it is sent to the session

    /// The drop at a place among the strip's tokens, as the tokens it lands between. A palette spacer or group is made here.
    public static func request(for drop: EditorDrop, onto strip: StripID, at index: Int, in context: DropContext) -> DropRequest {
        let tokens = rawTokens(of: strip, sections: context.sections, inventory: context.inventory, running: context.running, stale: context.stale)
        let moving = movingToken(drop, onto: strip)
        let remaining = tokens.filter { $0.id != moving?.id }
        var at = min(max(index, 0), tokens.count)
        if let moving, let position = tokens.firstIndex(where: { $0.id == moving.id }), position < at { at -= 1 }
        at = min(at, remaining.count)
        let created: NewOwnItem?
        switch drop {
        case .palette(.spacer): created = .spacer(LayoutSpacer())
        case .palette(.group): created = .group(IconGroup())
        default: created = nil
        }
        return DropRequest(drop: drop, strip: strip,
                           between: DropAnchors(left: at > 0 ? remaining[at - 1].id : nil, right: at < remaining.count ? remaining[at].id : nil),
                           created: created, canReorder: context.canReorder, cantReorder: context.cantReorder, running: context.running,
                           stale: context.stale)
    }

    /// What a request does on a model: the place is worked out again from the tokens the drop lands between, on this model, as the strip
    /// shows them now. Nil when it can't be done as the person dropped it, and nothing is to be written:
    /// - a token it lands beside is no longer in the strip (it left the list, or the section, or the app quit);
    /// - the two are no longer in the order they were;
    /// - the thing would not land between them on this model.
    public static func resolve(_ request: DropRequest, sections: SectionModel, inventory: Inventory) -> EditorOperation? {
        let context = DropContext(sections: sections, canReorder: request.canReorder, cantReorder: request.cantReorder,
                                  inventory: inventory, running: request.running, stale: request.stale)
        let place: Int
        if case .palette(let item) = request.drop, item != .marker, !request.canReorder {
            // Without the file it lands at the end of the section, whatever the place.
            place = 0
        } else {
            let tokens = rawTokens(of: request.strip, sections: sections, inventory: inventory, running: request.running,
                                   stale: request.stale)
            let moving = movingToken(request.drop, onto: request.strip)
            let remaining = tokens.filter { $0.id != moving?.id }
            let ids = remaining.map(\.id)
            var at: Int
            switch (request.between.left, request.between.right) {
            case (let left?, let right?):
                guard let l = ids.firstIndex(of: left), let r = ids.firstIndex(of: right), l < r else { return nil }
                at = l + 1
            case (let left?, nil):
                guard ids.contains(left) else { return nil }
                at = ids.count
            case (nil, let right?):
                guard ids.contains(right) else { return nil }
                at = 0
            case (nil, nil):
                at = 0
            }
            // As a drop counts it: with the moving token still in the strip.
            if let moving, let position = tokens.firstIndex(where: { $0.id == moving.id }), at >= position { at += 1 }
            place = at
        }
        switch decide(request.drop, onto: request.strip, at: place, in: context) {
        case .done(let operation): return operation
        case .declined: return nil
        }
    }

    /// Makes an operation on a model, as the session does. `created` is the spacer or group a palette drop makes. Returns the id of the
    /// token a spacer or a group makes.
    @discardableResult
    public static func apply(_ operation: EditorOperation, created: NewOwnItem?, to sections: inout SectionModel) -> String? {
        perform(operation, created: created, on: &sections)
    }

    /// The token a drop moves out of its place: the token itself when it is dropped on the strip it is in, or the marker, which is one.
    private static func movingToken(_ drop: EditorDrop, onto strip: StripID) -> StripToken? {
        switch drop {
        case .token(let token, let source): source == strip ? token : nil
        case .palette(.marker): .marker
        case .palette, .system: nil
        }
    }

    /// The drop as the strips now hold it: nil when it is a token that is no longer in the strip it came from (the app quit, the icon was
    /// removed while it was being dragged).
    public static func current(_ drop: EditorDrop, in strips: [Strip]) -> EditorDrop? {
        guard case .token(let token, let source) = drop else { return drop }
        guard let layout = strips.first(where: { $0.id == source })?.tokens.first(where: { $0.token.id == token.id }) else { return nil }
        return .token(layout.token, from: source)
    }

    private enum Decision {
        case done(EditorOperation)
        case declined
    }

    /// What is being put in a strip.
    fileprivate enum Subject {
        case app(bundleID: String, items: [ItemID])
        case own(ItemID)
        case newSpacer, newGroup
        case marker
    }

    private static func decide(_ drop: EditorDrop, onto strip: StripID, at index: Int, in context: DropContext) -> Decision {
        switch drop {
        case .system:
            return .done(.refused(LayoutEditorCopy.systemIconsKeepOrder))
        case .palette(let item):
            guard case .section(let section) = strip else { return .declined }
            // The marker moves no icon, so it needs no file: it lands where it is dropped. A spacer or a group lands at the end of the
            // section without one.
            if item != .marker, !context.canReorder {
                let end = context.sections.items(in: section).count
                return .done(item == .spacer ? .addSpacer(section, end) : .addGroup(section, end))
            }
            switch item {
            case .spacer: return placed(.newSpacer, removing: nil, onto: strip, at: index, in: context)
            case .group: return placed(.newGroup, removing: nil, onto: strip, at: index, in: context)
            // The marker is one: dropping it moves the one that is in the strip.
            case .marker: return placed(.marker, removing: .marker, onto: strip, at: index, in: context)
            }
        case .token(let token, let source):
            let removing: StripToken?
            if source == strip {
                let tokens = rawTokens(of: source, sections: context.sections, inventory: context.inventory, running: context.running, stale: context.stale)
                // On its own place: nothing moves.
                if let position = tokens.firstIndex(where: { $0.id == token.id }), index == position || index == position + 1 {
                    return .done(.noChange)
                }
                if let bundleID = token.bundleID, context.cantReorder.contains(bundleID) {
                    return .done(.refused(LayoutEditorCopy.cantPlaceThisIcon))
                }
                // The marker moves no icon: where it is only says where new icons go, so it needs no file.
                if !context.canReorder, token != .marker { return .done(.refused(LayoutCopy.needsGrantBanner)) }
                removing = token
            } else {
                removing = nil
            }
            let subject: Subject
            switch token {
            case .app(let bundleID, let items): subject = .app(bundleID: bundleID, items: items)
            case .own(let item): subject = .own(item)
            case .marker: subject = .marker
            }
            return placed(subject, removing: removing, onto: strip, at: index, in: context)
        }
    }

    /// The operation that puts `subject` at a place among a strip's tokens, once it is checked that the strip would show it there.
    private static func placed(_ subject: Subject, removing: StripToken?, onto strip: StripID, at index: Int,
                               in context: DropContext) -> Decision {
        let sections = context.sections
        let tokens = rawTokens(of: strip, sections: sections, inventory: context.inventory, running: context.running, stale: context.stale)
        let remaining = tokens.filter { $0.id != removing?.id }
        var at = min(max(index, 0), tokens.count)
        if let removing, let position = tokens.firstIndex(where: { $0.id == removing.id }), position < at { at -= 1 }
        at = min(at, remaining.count)

        let operation: EditorOperation
        switch strip {
        case .section(let section):
            let moving = movingIcons(of: subject, in: sections)
            guard let place = listPlace(in: section, remaining: remaining, at: at, moving: moving, isMarker: subject.isMarker,
                                        sections: sections) else { return .declined }
            switch subject {
            case .app(_, let items):
                guard let item = items.first else { return .declined }
                operation = .insert(item, section, place)
            case .own(let item): operation = .insert(item, section, place)
            case .newSpacer: operation = .addSpacer(section, place)
            case .newGroup: operation = .addGroup(section, place)
            case .marker: operation = .marker(section, place)
            }
        case .group(let group):
            // A group holds apps only.
            guard case .app(let bundleID, _) = subject else { return .declined }
            let members = (sections.groups[group]?.members ?? []).filter { $0 != bundleID }
            let memberPlace: (StripToken) -> Int? = { token in token.bundleID.flatMap { members.firstIndex(of: $0) } }
            let next = remaining[at...].lazy.compactMap(memberPlace).first
            let previous = remaining[..<at].reversed().lazy.compactMap(memberPlace).first.map { $0 + 1 }
            operation = .moveToGroup(bundleID: bundleID, group, next ?? previous ?? members.count)
        }

        // The check: make the change on a copy and see where the strip then shows the thing.
        var after = sections
        let made = perform(operation, created: nil, on: &after)
        let movedID: String
        switch subject {
        case .app(let bundleID, _): movedID = "app:\(bundleID)"
        case .own(let item): movedID = "own:\(item.string)"
        case .newSpacer, .newGroup: guard let made else { return .declined }; movedID = made
        case .marker: movedID = StripToken.marker.id
        }
        var expected = remaining.map(\.id)
        expected.insert(movedID, at: at)
        let known = Set(expected)
        // A token that arrives with the change (an app no list has follows the marker to its section) isn't what was dropped.
        let shown = rawTokens(of: strip, sections: after, inventory: context.inventory, running: context.running, stale: context.stale).map(\.id).filter(known.contains)
        return shown == expected ? .done(operation) : .declined
    }

    /// What the session does with an operation, on a model. Returns the id of the token a spacer or a group makes. `created` is the one
    /// a palette drop made; left out, a new one is made.
    @discardableResult
    private static func perform(_ operation: EditorOperation, created: NewOwnItem?, on sections: inout SectionModel) -> String? {
        switch operation {
        case .insert(let item, let section, let index):
            sections.insert(item, in: section, at: index)
        case .moveToGroup(let bundleID, let group, let index):
            sections.move(app: bundleID, toGroup: group, at: index)
        case .addSpacer(let section, let index):
            var spacer = LayoutSpacer()
            if case .spacer(let made)? = created { spacer = made }
            sections.addSpacer(spacer, in: section, at: index)
            return "own:\(OwnItems.itemID(spacer.id).string)"
        case .addGroup(let section, let index):
            var group = IconGroup()
            if case .group(let made)? = created { group = made }
            sections.addGroup(group, in: section, at: index)
            return "own:\(OwnItems.itemID(group.id).string)"
        case .marker(let section, let index):
            sections.setNewItemsMarker(section: section, index: index)
        case .noChange, .refused:
            break
        }
        return nil
    }

    /// The icons that leave the lists when `subject` is put somewhere: the app's, whichever list holds them, or the own item.
    private static func movingIcons(of subject: Subject, in sections: SectionModel) -> Set<ItemID> {
        switch subject {
        case .app(let bundleID, let items):
            return Set(items).union(allListedItems(sections).filter { $0.bundleID == bundleID && !$0.isSystem })
        case .own(let item):
            return [item]
        case .newSpacer, .newGroup, .marker:
            return []
        }
    }

    /// The place in a section's list that a place among the strip's tokens is, by the tokens beside it, with the `moving` icons out of
    /// the list: before the first icon of the first token at or after the place that the list holds an icon of; else after the last icon
    /// of the nearest such token before it; else at the end. (Not by counting icons: the list holds icons that have no token.)
    ///
    /// The marker is before the icon `newItemsIndex` names, and a token put at that icon lands left of it. A thing dropped beside the
    /// marker is put on that side of it, or nil when the list has no place on that side between its neighbours.
    private static func listPlace(in section: MenuBarSection, remaining: [StripToken], at place: Int, moving: Set<ItemID>,
                                  isMarker: Bool, sections: SectionModel) -> Int? {
        let full = sections.items(in: section)
        let list = full.filter { !moving.contains($0) }
        func span(of token: StripToken) -> ClosedRange<Int>? {
            let icons: [ItemID]
            switch token {
            case .app(_, let items): icons = items
            case .own(let item): icons = [item]
            case .marker: icons = []
            }
            let at = icons.compactMap { list.firstIndex(of: $0) }
            guard let first = at.min(), let last = at.max() else { return nil }
            return first...last
        }
        let next = remaining[place...].lazy.compactMap(span).first?.lowerBound
        let previous = remaining[..<place].reversed().lazy.compactMap(span).first.map { $0.upperBound + 1 }
        var chosen = next ?? previous ?? list.count
        guard !isMarker, let markerAt = remaining.firstIndex(of: .marker) else { return chosen }

        // Where the marker is in the list without the moving icons: before the first icon it was before that is still there.
        let markerPlace: Int
        if let index = sections.newItemsIndex {
            let anchor = full[min(max(index, 0), full.count)...].first { !moving.contains($0) }
            markerPlace = anchor.flatMap { list.firstIndex(of: $0) } ?? list.count
        } else {
            markerPlace = list.count
        }
        let low = previous ?? 0
        let high = next ?? list.count
        if markerAt >= place {
            // Left of the marker: at or before the icon it is before.
            chosen = min(chosen, markerPlace)
            return chosen >= low ? chosen : nil
        }
        // Right of the marker: after that icon, and still before the next token.
        guard markerPlace < list.count else { return nil }
        chosen = max(chosen, markerPlace + 1)
        return chosen <= high ? chosen : nil
    }
}

extension EditorOperation {
    /// The operation is a refusal.
    public var isRefused: Bool {
        if case .refused = self { true } else { false }
    }
}

fileprivate extension LayoutEditorModel.Subject {
    var isMarker: Bool {
        if case .marker = self { true } else { false }
    }
}

/// The words the editor's operations say.
public enum LayoutEditorCopy {
    public static let systemIconsKeepOrder = "System icons keep macOS's order."
    public static let cantPlaceThisIcon = "macOS gives Mantel no way to place this icon. ⌘-drag it in the menu bar."
}
