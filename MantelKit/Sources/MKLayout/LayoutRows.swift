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

    public init(id: String, name: String, iconCount: Int, isAuto: Bool, isNotAnswering: Bool = false, isTurnedOff: Bool = false) {
        self.id = id
        self.name = name
        self.iconCount = iconCount
        self.isAuto = isAuto
        self.isNotAnswering = isNotAnswering
        self.isTurnedOff = isTurnedOff
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
        isNotAnswering || isTurnedOff
    }

    /// What the row's status says in full, for a tooltip; empty for a row that has nothing to explain.
    public var helpText: String {
        if isNotAnswering { return LayoutCopy.notAnsweringHelp }
        if isTurnedOff { return LayoutCopy.offInSystemSettingsHelp }
        return ""
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

    public init(cantMove: [NamedRow], turnedOff: TurnedOffRows, missing: [NamedRow], overflow: [NamedRow], cantHideYet: [NamedRow]) {
        self.cantMove = cantMove
        self.turnedOff = turnedOff
        self.missing = missing
        self.overflow = overflow
        self.cantHideYet = cantHideYet
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
    /// An app whose name isn't in `names` is called what the menu bar read says it is called, and failing that, its bundle ID.
    public static func apps(inventory: Inventory, sections: SectionModel, names: [String: String],
                            turnedOff: TurnedOffList = .apps([])) -> [MenuBarSection: [AppRow]] {
        var grouped = Dictionary(uniqueKeysWithValues: MenuBarSection.allCases.map { ($0, [AppRow]()) })
        let answering = inventory.appsWithItems
        let off: Set<String> = if case .apps(let bundleIDs) = turnedOff { Set(bundleIDs) } else { [] }
        for bundleID in answering {
            let items = inventory.items(ofApp: bundleID)
            let readName = items.lazy.compactMap { $0.appName?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            let row = AppRow(id: bundleID, name: names[bundleID] ?? readName ?? bundleID, iconCount: items.count,
                             isAuto: sections.apps[bundleID]?.isAuto ?? false, isTurnedOff: off.contains(bundleID))
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

        return ReadOnlyRows(cantMove: sorted(cantMove), turnedOff: turnedOff, missing: named(lists.missing, names: names),
                            overflow: sorted(overflow), cantHideYet: sorted(cantHideYet))
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
        return ids
    }

    /// The apps a drop on `section` moves: the dropped text that is the bundle ID of an app listed in `rows`, once each, and not the
    /// ones in `section` already. Anything else that was dropped (text from elsewhere, an app that isn't listed) moves nothing.
    public static func droppedApps(_ dropped: [String], into section: MenuBarSection, rows: [MenuBarSection: [AppRow]]) -> [String] {
        let listedHere = Set((rows[section] ?? []).map(\.id))
        let listed = Set(rows.values.joined().map(\.id))
        var seen: Set<String> = []
        return dropped.filter { listed.contains($0) && !listedHere.contains($0) && seen.insert($0).inserted }
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

    public static let emptySection = "No apps here. Drag one in, or use an app's Move to menu."
    public static let moveTo = "Move to"
    public static let auto = "Auto"
    public static let autoHelp = "Moved here to make room. It moves back when there's room."
    /// Said in place of the count of icons for an app that didn't answer the last read.
    public static let notAnswering = "Not answering"
    public static let notAnsweringHelp = "This app didn't answer when Mantel last read the menu bar. It keeps its place."
    /// Said in place of the count of icons for an app whose switch is off in System Settings.
    public static let offInSystemSettings = "Off in System Settings"
    public static let offInSystemSettingsHelp = "macOS hides this app's icon because its switch is off in System Settings › Menu Bar. Turn it on there to let Mantel show and hide it."

    public static let newIconsHeader = "New icons"
    public static let newIconsPicker = "New icons go to"
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
    public static let none = "None."

    /// Said in place of the lists until the menu bar has been read.
    public static let notReadYet = "Mantel is still reading the menu bar."
}

/// Moves the person has asked for that the session hasn't made yet, so that Settings shows where an icon is going while the change is
/// being made (applying it can take seconds, with the System Settings switches).
///
/// A move is kept until the model says the icon is where it was asked to go, and no longer: another change to the sections (a read
/// that placed a new app, say) never ends it early, and it is never ended by a change to another icon.
public struct PendingMoves: Sendable, Equatable {
    public private(set) var apps: [String: MenuBarSection] = [:]
    public private(set) var systemItems: [String: MenuBarSection] = [:]
    public private(set) var newItems: MenuBarSection?

    public init() {}

    public var isEmpty: Bool {
        apps.isEmpty && systemItems.isEmpty && newItems == nil
    }

    public mutating func move(app bundleID: String, to section: MenuBarSection) { apps[bundleID] = section }
    public mutating func move(systemItem module: String, to section: MenuBarSection) { systemItems[module] = section }
    public mutating func setNewItems(_ section: MenuBarSection) { newItems = section }

    /// `sections` with these moves made, as a model that is only for showing (the person's moves are not "auto").
    public func applied(to sections: SectionModel) -> SectionModel {
        var shown = sections
        for (bundleID, section) in apps { shown.apps[bundleID] = AppPlacement(section: section, isAuto: false) }
        for (module, section) in systemItems { shown.systemItems[module] = section }
        if let newItems { shown.newItems = newItems }
        return shown
    }

    /// Lets go of the moves that `sections` has made: each icon whose section is the one asked for, and the new-items section when it is.
    public mutating func settle(against sections: SectionModel) {
        apps = apps.filter { sections.section(ofApp: $0.key) != $0.value }
        systemItems = systemItems.filter { (sections.systemItems[$0.key] ?? .shown) != $0.value }
        if newItems == sections.newItems { newItems = nil }
    }
}
