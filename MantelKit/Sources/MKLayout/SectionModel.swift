import MKCore

/// Where one app's icons are, and whether Mantel or the person put them there.
public struct AppPlacement: Codable, Sendable, Equatable {
    public var section: MenuBarSection
    /// Mantel moved the app (automatic overflow), so it may move it back when there is room. A move by the person is never
    /// automatic.
    public var isAuto: Bool

    public init(section: MenuBarSection, isAuto: Bool) {
        self.section = section
        self.isAuto = isAuto
    }
}

/// How the person has sorted icons into sections: Shown, Hidden and Always Hidden.
///
/// - **An app moves as one.** Every icon an app draws is in the app's section; moving one of them moves them all.
/// - **System items** (Wi-Fi, battery, …) are sorted one by one, by their module name.
/// - **`order`** lists the icons of each section in the order the layout editor shows them. It follows the moves, and the plan
///   never reads it.
/// - **`newItems`** is where an app first seen lands.
public struct SectionModel: Codable, Sendable, Equatable {
    /// By bundle ID.
    public var apps: [String: AppPlacement]
    /// By module name (`wifi`, `battery`): the section of a system item. A module with no entry is Shown.
    public var systemItems: [String: MenuBarSection]
    /// The icons of each section, in the order the layout editor shows them. A section with no icons has no entry.
    public var order: [MenuBarSection: [ItemID]]
    public var newItems: MenuBarSection

    public init() {
        apps = [:]
        systemItems = [:]
        order = [:]
        newItems = .shown
    }

    // MARK: Reading

    /// The section of an app: where it was put, or where new apps go when it was never put anywhere.
    public func section(ofApp bundleID: String) -> MenuBarSection {
        apps[bundleID]?.section ?? newItems
    }

    /// The section of an icon: its app's, or for a system item its own, which is Shown until it is moved.
    public func section(of item: ItemID) -> MenuBarSection {
        switch item.key {
        case .system(let module): systemItems[module] ?? .shown
        case .identifier, .index: section(ofApp: item.bundleID)
        }
    }

    // MARK: Changing

    /// The person moves an app. It can't be moved back by Mantel afterwards (`isAuto` is cleared).
    public mutating func move(app bundleID: String, to section: MenuBarSection) {
        place(app: bundleID, in: section, isAuto: false)
    }

    /// The person moves an icon: its whole app, or for a system item the item itself.
    public mutating func move(item: ItemID, to section: MenuBarSection) {
        switch item.key {
        case .system(let module):
            systemItems[module] = section
        case .identifier, .index:
            place(app: item.bundleID, in: section, isAuto: false)
        }
        // The icon is listed even if no scan has noted it yet.
        file([item], under: section)
    }

    /// Gives each app that has no placement a place in `newItems`, as its own choice (`isAuto` false), and returns the apps it
    /// placed, in the order they were given. The ones that were placed already are left where they are.
    ///
    /// The caller gives the apps that have items in the menu bar (`Inventory.appsWithItems`): an app with none is never placed.
    @discardableResult
    public mutating func assignNew(apps bundleIDs: [String]) -> [String] {
        var placed: [String] = []
        for bundleID in bundleIDs where apps[bundleID] == nil {
            apps[bundleID] = AppPlacement(section: newItems, isAuto: false)
            placed.append(bundleID)
        }
        return placed
    }

    /// Drops what is known of an app: its placement, and its icons from `order`. It is placed again, in `newItems`, if it shows
    /// up again.
    public mutating func forget(app bundleID: String) {
        apps[bundleID] = nil
        let gone = Set(listedItems(ofApp: bundleID))
        guard !gone.isEmpty else { return }
        for section in MenuBarSection.allCases {
            guard let list = order[section] else { continue }
            let kept = list.filter { !gone.contains($0) }
            order[section] = kept.isEmpty ? nil : kept
        }
    }

    /// Lists the icons that the layout editor doesn't know yet, at the end of the section each is in. An icon that is listed under
    /// another section than its own is moved to its own.
    ///
    /// Mantel's own icons are left out: they are in no section.
    public mutating func note(_ items: [MenuBarItem]) {
        for item in items where !item.isMantel {
            file([item.id], under: section(of: item.id))
        }
    }

    /// Puts an app in a section and its listed icons with it. Automatic overflow moves apps this way, without the person's say.
    mutating func place(app bundleID: String, in section: MenuBarSection, isAuto: Bool) {
        apps[bundleID] = AppPlacement(section: section, isAuto: isAuto)
        file(listedItems(ofApp: bundleID), under: section)
    }

    // MARK: The order lists

    /// The icons of an app that `order` lists, whichever section they are listed under.
    private func listedItems(ofApp bundleID: String) -> [ItemID] {
        MenuBarSection.allCases.flatMap { order[$0] ?? [] }.filter { $0.bundleID == bundleID && !$0.isSystem }
    }

    /// Makes `section`'s list the only one that holds `items`: they leave every other list, and join this one at the end unless
    /// they are in it already. A list left empty is dropped.
    private mutating func file(_ items: [ItemID], under section: MenuBarSection) {
        let moving = Set(items)
        for other in MenuBarSection.allCases where other != section {
            guard let list = order[other] else { continue }
            let kept = list.filter { !moving.contains($0) }
            order[other] = kept.isEmpty ? nil : kept
        }
        var list = order[section] ?? []
        var listed = Set(list)
        for item in items where listed.insert(item).inserted {
            list.append(item)
        }
        order[section] = list.isEmpty ? nil : list
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case apps, systemItems, order, newItems
    }

    // A key missing from the file takes its default, so a file written before a key was added is still read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apps = try container.decodeIfPresent([String: AppPlacement].self, forKey: .apps) ?? [:]
        systemItems = try container.decodeIfPresent([String: MenuBarSection].self, forKey: .systemItems) ?? [:]
        order = try container.decodeIfPresent([MenuBarSection: [ItemID]].self, forKey: .order) ?? [:]
        newItems = try container.decodeIfPresent(MenuBarSection.self, forKey: .newItems) ?? .shown
    }
}
