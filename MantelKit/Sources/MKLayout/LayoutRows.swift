import Foundation
import MKCore

/// One app in a section of the Layout pane.
public struct AppRow: Sendable, Equatable, Identifiable {
    /// The app's bundle ID.
    public let id: String
    public let name: String
    /// How many icons the app draws in the menu bar.
    public let iconCount: Int
    /// Mantel moved the app here because it didn't fit, and moves it back when there is room.
    public let isAuto: Bool
    /// The app is running and was asked for its icons, and didn't answer (it timed out, or is left alone for a while). It keeps its place
    /// in its section, and its icons aren't counted.
    public let isNotAnswering: Bool
    /// The app's switch is off in System Settings › Menu Bar: macOS doesn't draw its icons, so a reveal can't show them. (Never set on
    /// a row that is not answering: that says more.)
    public let isTurnedOff: Bool
    /// macOS doesn't tie the app's icon to the app, so while the allowlist is in use the icon is hidden whenever anything is. (Never set
    /// on a row that is not answering or turned off, and only while the allowlist is the way of hiding: under the switches the icon is
    /// shown, and the sentence would be false.)
    public let isUnattached: Bool

    public init(id: String, name: String, iconCount: Int, isAuto: Bool, isNotAnswering: Bool = false, isTurnedOff: Bool = false,
                isUnattached: Bool = false) {
        self.id = id
        self.name = name
        self.iconCount = iconCount
        self.isAuto = isAuto
        self.isNotAnswering = isNotAnswering
        self.isTurnedOff = isTurnedOff
        self.isUnattached = isUnattached
    }

    /// A line under the row that says what is the matter with the app's icon, when it is the one thing that is: nil for a row that has
    /// nothing to say. It holds in any section.
    public var note: String? {
        isUnattached ? LayoutCopy.unattachedIcon : nil
    }

    /// "1 icon" or "3 icons".
    public var iconCountText: String {
        iconCount == 1 ? "1 icon" : "\(iconCount) icons"
    }

    /// What the row says of the app's icons: that the app isn't answering, that macOS has it turned off, or else how many icons it has.
    public var statusText: String {
        if isNotAnswering { return LayoutCopy.notAnswering }
        if isTurnedOff { return LayoutCopy.offInSystemSettings }
        return iconCountText
    }

    /// The row says something is wrong with the app's icons: it is drawn in a colour of its own.
    public var needsAttention: Bool {
        isNotAnswering || isTurnedOff || isUnattached
    }

    /// What the row's status says in full, for a tooltip; empty for a row that has nothing to explain.
    public var helpText: String {
        if isNotAnswering { return LayoutCopy.notAnsweringHelp }
        if isTurnedOff { return LayoutCopy.offInSystemSettingsHelp }
        return note ?? ""
    }
}

/// One of macOS's own icons in the Layout pane's list of system icons.
public struct SystemRow: Sendable, Equatable, Identifiable {
    /// The module: `wifi` for `com.apple.menuextra.wifi`.
    public let id: String
    public let title: String
    public let section: MenuBarSection
    /// Whether the person can move it. The clock and Control Center can't be moved until hiding them is allowed.
    public let canChange: Bool

    public init(id: String, title: String, section: MenuBarSection, canChange: Bool) {
        self.id = id
        self.title = title
        self.section = section
        self.canChange = canChange
    }
}

/// A line in one of the lists that explain what can't be changed: what to call it, and what identifies it.
public struct NamedRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The apps macOS has turned off in System Settings, as the Layout pane lists them: by name, or why Mantel can't tell.
public enum TurnedOffRows: Sendable, Equatable {
    case unavailable(String)
    case apps([NamedRow])
}

/// The lists that explain what can't be changed, with names for the person.
public struct ReadOnlyRows: Sendable, Equatable {
    public let cantMove: [NamedRow]
    public let turnedOff: TurnedOffRows
    public let missing: [NamedRow]
    public let overflow: [NamedRow]
    public let cantHideYet: [NamedRow]
    /// The apps whose place macOS gives Mantel no way to set.
    public let cantReorder: [NamedRow]

    public init(cantMove: [NamedRow], turnedOff: TurnedOffRows, missing: [NamedRow], overflow: [NamedRow], cantHideYet: [NamedRow],
                cantReorder: [NamedRow] = []) {
        self.cantMove = cantMove
        self.turnedOff = turnedOff
        self.missing = missing
        self.overflow = overflow
        self.cantHideYet = cantHideYet
        self.cantReorder = cantReorder
    }
}

/// What the Layout pane lists, decided here so that the pane only draws it. It takes values of `MKCore` and `MKLayout` only: names
/// come in as a dictionary the app makes (what the running app calls itself, else its bundle's name, else its bundle ID).
public enum LayoutRows {
    /// The apps that have icons in the menu bar, in the section each is in, each list by name (`NameOrdering`). Every section has a
    /// list, empty or not. Mantel's own icons and the system's are not apps here.
    ///
    /// A running app that didn't answer the read (`Inventory.unansweredApps`) has no icons in it, and is still listed, in the section it
    /// was placed in, if it was placed (`isNotAnswering`): a row that came and went with each read couldn't be moved, or dragged.
    /// Every app seen with icons has a placement (the session places it when it reads it), so one that never answered has none and
    /// isn't listed.
    ///
    /// An app that macOS has turned off in System Settings (`turnedOff`) is marked (`isTurnedOff`): its icons are in the read, but macOS
    /// doesn't draw them, whatever section the app is in. Nothing is marked when the list can't be read, and an app that didn't answer
    /// is marked as that and nothing else.
    ///
    /// An app in `unattached` (macOS doesn't tie its icon to it) is marked (`isUnattached`) while the allowlist is in use (`allowlistInUse`),
    /// in any section, unless it is turned off or didn't answer: those say more.
    ///
    /// An app whose name isn't in `names` is called what the menu bar read says it is called, and failing that, its bundle ID.
    public static func apps(inventory: Inventory, sections: SectionModel, names: [String: String],
                            turnedOff: TurnedOffList = .apps([]), unattached: Set<String> = [],
                            allowlistInUse: Bool = false) -> [MenuBarSection: [AppRow]] {
        var grouped = Dictionary(uniqueKeysWithValues: MenuBarSection.allCases.map { ($0, [AppRow]()) })
        let answering = inventory.appsWithItems
        let off: Set<String> = if case .apps(let bundleIDs) = turnedOff { Set(bundleIDs) } else { [] }
        for bundleID in answering {
            let items = inventory.items(ofApp: bundleID)
            let readName = items.lazy.compactMap { $0.appName?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            let row = AppRow(id: bundleID, name: names[bundleID] ?? readName ?? bundleID, iconCount: items.count,
                             isAuto: sections.apps[bundleID]?.isAuto ?? false, isTurnedOff: off.contains(bundleID),
                             isUnattached: allowlistInUse && unattached.contains(bundleID) && !off.contains(bundleID))
            grouped[sections.section(ofApp: bundleID), default: []].append(row)
        }
        for bundleID in inventory.unansweredApps.subtracting(answering) {
            guard let placement = sections.apps[bundleID] else { continue }
            let row = AppRow(id: bundleID, name: names[bundleID] ?? bundleID, iconCount: 0, isAuto: placement.isAuto, isNotAnswering: true)
            grouped[placement.section, default: []].append(row)
        }
        return grouped.mapValues { NameOrdering.sorted($0, name: \.name, tiebreak: \.id) }
    }

    /// One row for each of macOS's own icons that Mantel can hide: the ones in the menu bar, and the ones that were put in a section
    /// (a hidden icon may be missing from the read, and the person has to be able to move it back). By title. The clock and Control
    /// Center show as Shown, whatever was stored, until hiding them is allowed.
    public static func system(inventory: Inventory, sections: SectionModel, allowClockAndControlCenter: Bool) -> [SystemRow] {
        var modules: [String] = []
        for item in inventory.items {
            if case .system(let module) = item.id.key, !modules.contains(module) { modules.append(module) }
        }
        for module in sections.systemItems.keys where !modules.contains(module) { modules.append(module) }

        let rows = modules.compactMap { module -> SystemRow? in
            // An icon Mantel has no number for can't be hidden, so it has no place in the sections (it is listed apart).
            guard SystemItemTable.number(of: module) != nil else { return nil }
            let canChange = !SystemItemTable.unmovable.contains(module) || allowClockAndControlCenter
            // What the plan does: while hiding them isn't allowed, the clock and Control Center are on the bar whatever section is stored.
            return SystemRow(id: module, title: SystemItemTable.title(of: module) ?? module,
                             section: canChange ? (sections.systemItems[module] ?? .shown) : .shown, canChange: canChange)
        }
        return NameOrdering.sorted(rows, name: \.title, tiebreak: \.id)
    }

    /// The lists that explain what can't be changed, with the names the person knows the apps by.
    ///
    /// - The clock and Control Center are listed as ones that can't be moved only while hiding them isn't allowed.
    /// - An app that is in the « overflow is listed once, however many of its icons are.
    /// - An icon Mantel can't hide yet is called by its label, or failing that its module.
    public static func readOnly(lists: ReadOnlyLists, inventory: Inventory, names: [String: String],
                                allowClockAndControlCenter: Bool) -> ReadOnlyRows {
        let cantMove = allowClockAndControlCenter ? [] : lists.cantMove.map { row(for: $0, inventory: inventory, names: names) }

        let turnedOff: TurnedOffRows
        switch lists.turnedOff {
        case .unavailable(let reason): turnedOff = .unavailable(reason)
        case .apps(let bundleIDs): turnedOff = .apps(named(bundleIDs, names: names))
        }

        var seen: Set<String> = []
        let overflow = lists.overflow.map { row(for: $0, inventory: inventory, names: names) }.filter { seen.insert($0.id).inserted }

        let cantHideYet = lists.cantHideYet.map { id -> NamedRow in
            let label = inventory.items.first { $0.id == id }?.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let label, !label.isEmpty { return NamedRow(id: id.string, name: label) }
            return row(for: id, inventory: inventory, names: names)
        }

        let cantReorder = named(Array(cantReorderApps(lists: lists)), names: names)

        return ReadOnlyRows(cantMove: sorted(cantMove), turnedOff: turnedOff, missing: named(lists.missing, names: names),
                            overflow: sorted(overflow), cantHideYet: sorted(cantHideYet), cantReorder: cantReorder)
    }

    /// The apps that can't be reordered: the owners of the icons in `lists.cantReorder`, once each. A system icon or one of Mantel's own
    /// is no app's, and isn't one of them.
    public static func cantReorderApps(lists: ReadOnlyLists) -> Set<String> {
        Set(lists.cantReorder.filter { !$0.isSystem && $0.bundleID != OwnItems.owner }.map(\.bundleID))
    }

    /// Bundle IDs with the names they go by, in order of name.
    public static func named(_ bundleIDs: [String], names: [String: String]) -> [NamedRow] {
        sorted(bundleIDs.map { NamedRow(id: $0, name: names[$0] ?? $0) })
    }

    /// The bundle IDs that `apps(…)` and `readOnly(…)` give names to: every app they list. The app finds a name for each of these.
    public static func appIDs(inventory: Inventory, sections: SectionModel, lists: ReadOnlyLists) -> Set<String> {
        var ids = Set(inventory.appsWithItems)
        ids.formUnion(inventory.unansweredApps.filter { sections.apps[$0] != nil })
        ids.formUnion(lists.missing)
        if case .apps(let turnedOff) = lists.turnedOff { ids.formUnion(turnedOff) }
        ids.formUnion(lists.overflow.filter { !$0.isSystem }.map(\.bundleID))
        ids.formUnion(cantReorderApps(lists: lists))
        return ids
    }

    // MARK: Pieces

    /// How an icon is named in a list: a system icon by its title, an app's icon by the name of its app.
    private static func row(for id: ItemID, inventory: Inventory, names: [String: String]) -> NamedRow {
        if case .system(let module) = id.key {
            return NamedRow(id: id.string, name: SystemItemTable.title(of: module) ?? module)
        }
        let readName = inventory.items.first { $0.id == id }?.appName
        let name = names[id.bundleID] ?? (readName?.isEmpty == false ? readName : nil) ?? id.bundleID
        return NamedRow(id: id.bundleID, name: name)
    }

    private static func sorted(_ rows: [NamedRow]) -> [NamedRow] {
        NameOrdering.sorted(rows, name: \.name, tiebreak: \.id)
    }
}

/// The words of the Layout pane.
public enum LayoutCopy {
    /// The line under each section of apps.
    public static func footer(for section: MenuBarSection) -> String {
        switch section {
        case .shown: "Always in the menu bar."
        case .hidden: "Shown when you click •, or by the ways you chose in General."
        case .alwaysHidden: "Shown only when you click ••."
        }
    }

    public static let moveTo = "Move to"
    public static let moveLeft = "Move Left"
    public static let moveRight = "Move Right"
    public static let auto = "Auto"
    public static let autoHelp = "Moved here to make room. It moves back when there's room."
    /// Said in place of the count of icons for an app that didn't answer the last read.
    public static let notAnswering = "Not answering"
    public static let notAnsweringHelp = "This app didn't answer when Mantel last read the menu bar. It keeps its place."
    /// Said in place of the count of icons for an app whose switch is off in System Settings.
    public static let offInSystemSettings = "Off in System Settings"
    public static let offInSystemSettingsHelp = "macOS hides this app's icon because its switch is off in System Settings › Menu Bar. Turn it on there to let Mantel show and hide it."

    /// The note under the row of an app whose icon macOS doesn't tie to it, while the allowlist is in use.
    public static let unattachedIcon = "macOS can't tell which app this icon belongs to, so it's hidden whenever anything is hidden."

    public static let overflowToggle = "Move icons that don't fit to Hidden"
    public static let overflowFooter = "When the menu bar is full or the notch is in the way, apps move to Hidden instead of disappearing into «, so the dots stay in sight. They move back when there's room."

    public static let systemIconsHeader = "System icons"
    public static let systemIconsFooter = "To hide the clock or Control Center, allow it in Advanced."

    public static let readOnlyHeader = "Can't be changed here"
    public static let cantMoveTitle = "Can't move"
    public static let cantMoveCaption = "macOS keeps these in place."
    public static let turnedOffTitle = "Turned off in System Settings"
    public static let missingTitle = "Missing"
    public static let missingCaption = "Apps you've placed that aren't running."
    public static let forget = "Forget"
    public static let overflowTitle = "In the « overflow"
    public static let overflowCaption = "macOS moved these out of sight because the menu bar is full."
    public static let cantHideYetTitle = "Can't be hidden yet"
    public static let cantHideYetCaption = "Mantel doesn't know how to hide these system icons yet."
    public static let cantReorderTitle = "Can't reorder"
    public static let cantReorderCaption = "macOS gives Mantel no way to place these. ⌘-drag them in the menu bar."
    public static let none = "None."

    /// Said in place of the lists until the menu bar has been read.
    public static let notReadYet = "Mantel is still reading the menu bar."

    // MARK: The editor

    public static let grantAccessButton = "Grant Access…"
    /// Said by the banner when the order can't be written for want of the file, and by the refusal of a reorder.
    public static let needsGrantBanner = "Grant access to reorder, or ⌘-drag in the menu bar"
    public static let notAcceptedBanner = "macOS didn't accept the last order. Try the change again, or ⌘-drag in the menu bar."
    public static let notPlacedBanner = "Some of Mantel's icons couldn't be placed among icons it can't reorder. ⌘-drag them in the menu bar."
    public static func addedAtTheEnd(of section: MenuBarSection) -> String {
        "Added at the end of \(section.title). ⌘-drag it into place in the menu bar."
    }

    public static let groupedHeader = "Grouped"
    public static let noGroups = "No groups yet. Add one below."
    public static let groupedFooter = "Grouped icons open from their group's icon. •• shows them too."
    public static let emptyStrip = "Drag icons here"
    public static let paletteHeader = "Add to the menu bar"
    public static let paletteFooter = "Drag one into a row."
    public static let paletteSpacer = "Spacer"
    public static let paletteGroup = "Group"
    public static let paletteMarker = "New icons go here"
    public static let add = "Add"
    public static func paletteTitle(_ item: PaletteItem) -> String {
        switch item {
        case .spacer: paletteSpacer
        case .group: paletteGroup
        case .marker: paletteMarker
        }
    }
    public static func paletteSymbol(_ item: PaletteItem) -> String {
        switch item {
        case .spacer: "arrow.left.and.right"
        case .group: "square.grid.2x2"
        case .marker: "plus.square.dashed"
        }
    }

    public static let selectedIconHeader = "Selected icon"
    public static func iconCount(_ count: Int) -> String { count == 1 ? "1 icon" : "\(count) icons" }
    /// Said of an app that draws several icons: `count` is the number of the others.
    public static func movesWithOthers(count: Int, app: String) -> String {
        "Moves with \(count) other \(count == 1 ? "icon" : "icons") from \(app)"
    }
    public static let searchNames = "Search names"
    public static let searchNamesPrompt = "Other names, separated by commas"
    public static func shortcut(_ combo: String?) -> String { "Shortcut: \(combo ?? "None")" }
    public static let editInHotkeys = "Edit in Hotkeys"
    public static let width = "Width"
    public static let label = "Label"
    public static let labelNone = "None"
    public static let labelText = "Text"
    public static let labelEmoji = "Emoji"
    public static let labelSymbol = "SF Symbol"
    public static let title = "Title"
    public static let look = "Look"
    public static let lookSymbol = "SF Symbol"
    public static let lookEmoji = "Emoji"
    public static let lookImage = "Image…"
    public static let opensOnHover = "Open when the pointer rests on it"
    public static let markerNote = "New icons appear here."
    public static let remove = "Remove"
    public static let cantReorderHelp = "Can't reorder: ⌘-drag it in the menu bar."
    public static let cantReorderLabel = "can't reorder"

    public static let optionsHeader = "Options"
    public static let keepDotsBesideClock = "Keep the dots beside the clock"
    public static let keepDotsFooter = "They stay in place when icons show, and macOS's « never takes them. Hidden icons then appear left of your shown icons."
    public static let showAllWhileDragging = "Show all sections while ⌘-dragging"
    public static let recaptureIcons = "Recapture icons"
    public static let restoreOriginal = "Restore original layout…"
    public static let restoreTitle = "Restore the original layout?"
    public static let restoreText = "Mantel puts the menu bar icons back in the order they had before Mantel first changed it. Your sections stay as they are."
    public static let restore = "Restore"
    public static let cancel = "Cancel"
}

/// Changes the person has asked for that the session hasn't made yet, so that Settings shows where an icon is going while the change is
/// being made (applying it can take seconds, with the System Settings switches).
///
/// - **Every change the pane sends is kept**: a drop, a menu's move or add, a system icon's section, Remove and Forget. Each is made on
///   the model with the call the session makes, so what is shown is what the session will have. A change that is left out would leave the
///   strips showing a list the session doesn't have, and a drop worked out on it would land somewhere else.
/// - **A drop is kept as the tokens it lands between** (`DropRequest`), and its place is worked out again each time it is shown: on the
///   model as it is with the changes before it made, which is the model the session applies it to.
/// - **A change is kept until the model has it, and no longer:** it is let go when making it on the model changes nothing (the model
///   is as it asked, or the model wouldn't make it: the app was forgotten, a token it lands beside has left). That is judged in the
///   order they were asked, on the model with the changes kept before it made, so a change that depends on an earlier one the model
///   doesn't have yet is kept. A palette's spacer or group is let go once the model lists it. Another change to the sections (a read
///   that placed a new app, say) never ends it early, and it is never ended by a change to another icon. One that changes nothing when
///   it is asked for is not kept.
public struct PendingMoves: Sendable, Equatable {
    /// What was asked.
    public enum Edit: Sendable, Equatable {
        /// An icon, an app, an own item, the marker, or a palette's spacer or group, put between two tokens of a strip.
        case drop(DropRequest)
        /// A system icon put in a section.
        case system(module: String, MenuBarSection)
        /// A spacer or a group taken off the layout.
        case remove(ItemID)
        /// What is known of an app dropped.
        case forget(bundleID: String)

        /// What the edit is of: a later one of the same thing replaces the earlier.
        fileprivate var subject: String {
            switch self {
            case .drop(let request):
                switch (request.drop, request.created) {
                case (.token(.marker, _), _), (.palette(.marker), _): "marker"
                case (.token(.own(let item), _), _): "own:\(item.string)"
                case (.token(.app(let bundleID, _), _), _): "app:\(bundleID)"
                case (.system(let item), _): "system:\(item.string)"
                case (.palette, .spacer(let spacer)?): "own:\(OwnItems.itemID(spacer.id).string)"
                case (.palette, .group(let group)?): "own:\(OwnItems.itemID(group.id).string)"
                case (.palette, nil): "palette"
                }
            case .system(let module, _): "system:\(ItemID.system(module).string)"
            case .remove(let item): "own:\(item.string)"
            case .forget(let bundleID): "app:\(bundleID)"
            }
        }

        fileprivate func made(on sections: SectionModel, inventory: Inventory) -> SectionModel {
            var shown = sections
            switch self {
            case .drop(let request):
                // A palette add is the one that made the spacer or group: once the model lists it, it is done, and it is never made again
                // over the model (that would put back the fields it was made with over the ones the person has set since).
                switch request.created {
                case .spacer(let spacer)? where sections.spacers[spacer.id] != nil: return sections
                case .group(let group)? where sections.groups[group.id] != nil: return sections
                default: break
                }
                if let operation = LayoutEditorModel.resolve(request, sections: sections, inventory: inventory) {
                    LayoutEditorModel.apply(operation, created: request.created, to: &shown)
                }
            case .system(let module, let section):
                // Shown until it is put somewhere: asking for Shown changes nothing where it is listed under Shown and never put elsewhere.
                let item = ItemID.system(module)
                if (shown.systemItems[module] ?? .shown) != section || !shown.items(in: section).contains(item) {
                    shown.move(item: item, to: section)
                }
            case .remove(let item): shown.removeOwnItem(item)
            case .forget(let bundleID): shown.forget(app: bundleID)
            }
            return shown
        }
    }

    public private(set) var edits: [Edit] = []

    public init() {}

    public var isEmpty: Bool {
        edits.isEmpty
    }

    /// Keeps what was asked, on `sections` as they are now (with the changes before it made): nothing is kept when it changes nothing there.
    public mutating func ask(_ edit: Edit, on sections: SectionModel, inventory: Inventory) {
        edits.removeAll { $0.subject == edit.subject }
        if edit.made(on: sections, inventory: inventory) != sections { edits.append(edit) }
    }

    /// `sections` with these changes made, in the order they were asked: as a model that is only for showing (the person's moves are not
    /// "auto").
    public func applied(to sections: SectionModel, inventory: Inventory) -> SectionModel {
        edits.reduce(sections) { $1.made(on: $0, inventory: inventory) }
    }

    /// Lets go of the changes that `sections` has made: each one that changes nothing on it with the changes kept before it made, which
    /// is the model the session applies it to (the session makes them in the order they were asked, so a later one can depend on an
    /// earlier one that `sections` doesn't have yet).
    public mutating func settle(against sections: SectionModel, inventory: Inventory) {
        var shown = sections
        var kept: [Edit] = []
        for edit in edits {
            let made = edit.made(on: shown, inventory: inventory)
            guard made != shown else { continue }
            kept.append(edit)
            shown = made
        }
        edits = kept
    }
}
