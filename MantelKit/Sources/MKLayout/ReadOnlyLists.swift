import MKCore

/// The apps macOS has turned off in System Settings, or why Mantel can't say.
public enum TurnedOffList: Sendable, Equatable {
    /// Mantel can't read the list, for this reason (words for the person).
    case unavailable(String)
    /// The bundle IDs of the apps whose switch is off.
    case apps([String])
}

/// The lists in Settings that explain what can't be changed, and why.
public struct ReadOnlyLists: Sendable, Equatable {
    /// The clock and Control Center, when they are in the menu bar: they can't be moved out of Shown unless the person allows it.
    public var cantMove: [ItemID]
    /// The apps turned off in System Settings, as given.
    public var turnedOff: TurnedOffList
    /// The apps that were put in a section other than the one new apps go to and aren't running. By bundle ID, sorted.
    public var missing: [String]
    /// The items in the « overflow or behind the notch, on any display.
    public var overflow: [ItemID]
    /// The system items Mantel has no number for, so it can't hide them yet.
    public var cantHideYet: [ItemID]
    /// The items no key in macOS's order table could be found for, so their app can't be put in an order: a position is written under a
    /// key, and an item that names itself to nothing has one only when the key match finds it (`KeyMatchRule`), and none when the app's
    /// keys and items don't line up, or when the app sits among the modules that stay (Wi‑Fi, Battery and the like).
    public var cantReorder: [ItemID]

    public init(cantMove: [ItemID], turnedOff: TurnedOffList, missing: [String], overflow: [ItemID], cantHideYet: [ItemID],
                cantReorder: [ItemID] = []) {
        self.cantMove = cantMove
        self.turnedOff = turnedOff
        self.missing = missing
        self.overflow = overflow
        self.cantHideYet = cantHideYet
        self.cantReorder = cantReorder
    }

    /// Builds the lists from the last inventory.
    ///
    /// - `running`: the bundle IDs of the running apps. An app is **missing** only when it is placed and isn't in this set, so an app
    ///   that is running but didn't answer when the menu bar was read (`Inventory.unansweredApps`) is never missing, however few
    ///   of its items the inventory holds.
    /// - A placement that is what a new app gets anyway (`AppPlacement(section: newItems, isAuto: false)`) says nothing the person
    ///   chose, so such an app is left out of **missing**.
    /// - `unresolved`: the items the last key resolution found no key for (`LayoutKeyResolution.unresolved`), given as **cantReorder**
    ///   when the inventory holds them (the resolution covers every icon in the model, and an app that has quit isn't listed twice).
    public static func make(inventory: Inventory, sections: SectionModel, running: Set<String>, turnedOff: TurnedOffList,
                            unresolved: [ItemID] = []) -> ReadOnlyLists {
        let moduleOf: (ItemID) -> String? = { id in
            if case .system(let module) = id.key { module } else { nil }
        }
        let cantMove = inventory.items.map(\.id).filter { id in
            moduleOf(id).map(SystemItemTable.unmovable.contains) ?? false
        }
        let cantHideYet = inventory.items.map(\.id).filter { id in
            moduleOf(id).map { SystemItemTable.number(of: $0) == nil } ?? false
        }
        let overflow = inventory.items.filter(\.isOverflowed).map(\.id)
        let present = Set(inventory.items.map(\.id))

        let byDefault = AppPlacement(section: sections.newItems, isAuto: false)
        let missing = sections.apps
            .filter { !running.contains($0.key) && $0.value != byDefault }
            .keys.sorted()

        return ReadOnlyLists(cantMove: cantMove, turnedOff: turnedOff, missing: missing, overflow: overflow, cantHideYet: cantHideYet,
                             cantReorder: unresolved.filter { present.contains($0) })
    }
}
