import MKCore

/// Where one app's icons are, and whether Mantel or the person put them there.
public struct AppPlacement: Codable, Sendable, Equatable {
    public var section: MenuBarSection
    /// Mantel moved the app (automatic overflow), so it may move it back when there is room. A move by the person is never
    /// automatic.
    public var isAuto: Bool
    /// The group the app is in. A grouped app's section is Always Hidden, so the dots show it like any app there.
    public var group: GroupID?

    public init(section: MenuBarSection, isAuto: Bool, group: GroupID? = nil) {
        self.section = section
        self.isAuto = isAuto
        self.group = group
    }
}

/// How the person has sorted icons into sections: Shown, Hidden and Always Hidden, and the spacers and groups they added.
///
/// - **An app moves as one.** Every icon an app draws is in the app's section; moving one of them moves them all, together and in their
///   order.
/// - **System items** (Wi-Fi, battery, …) are sorted one by one, by their module name.
/// - **`order`** lists the icons of each section in the order the layout editor shows them. It follows the moves, and the plan
///   never reads it. A spacer's and a group's own icons are in it too, as `OwnItems.itemID` names them.
/// - **Groups** hold apps (`groups`, in `groupOrder`). A grouped app's icons are in `groupItems`, in the order of the group's members,
///   and never in a section's list.
/// - **`newItems`** is where an app first seen lands: at the end of its section's list, or at the marker (`newItemsIndex`) when the
///   person has put it somewhere.
public struct SectionModel: Codable, Sendable, Equatable {
    /// By bundle ID.
    public var apps: [String: AppPlacement]
    /// By module name (`wifi`, `battery`): the section of a system item. A module with no entry is Shown.
    public var systemItems: [String: MenuBarSection]
    /// The icons of each section, in the order the layout editor shows them. A section with no icons has no entry.
    public var order: [MenuBarSection: [ItemID]]
    /// The section where apps that are new go. Choosing another forgets the place of the marker in the one before.
    public var newItems: MenuBarSection {
        didSet {
            if newItems != oldValue { newItemsIndex = nil }
        }
    }
    /// The spacers the person added.
    public var spacers: [SpacerID: LayoutSpacer]
    /// The groups the person added.
    public var groups: [GroupID: IconGroup]
    /// The groups in the order the layout editor lists them.
    public var groupOrder: [GroupID]
    /// The icons of the apps in each group, in the order of its members.
    public var groupItems: [GroupID: [ItemID]]
    /// Where the marker for new apps is in `order[newItems]`: it is before the icon at this index, or after the last when it is the
    /// length of the list. Nil when the person never put it anywhere: new apps then go to the end. Every change to the list keeps the
    /// marker before the same icon.
    public var newItemsIndex: Int?
    /// The apps whose saved icons haven't been checked against what the app lists yet (`reconcile`): they were saved by an older version,
    /// which could save an icon of an app under names that were never its own. An app that is in it shows one icon in the places that
    /// list icons until its first whole read; an app that is not is believed in full.
    public var unchecked: Set<String>

    public init() {
        apps = [:]
        systemItems = [:]
        order = [:]
        newItems = .shown
        spacers = [:]
        groups = [:]
        groupOrder = []
        groupItems = [:]
        newItemsIndex = nil
        unchecked = []
    }

    // MARK: Reading

    /// The section of an app: where it was put, or where new apps go when it was never put anywhere.
    public func section(ofApp bundleID: String) -> MenuBarSection {
        apps[bundleID]?.section ?? newItems
    }

    /// The section of an icon: its app's, or for a system item its own, which is Shown until it is moved. For a spacer or a group's icon,
    /// the section whose list holds it.
    public func section(of item: ItemID) -> MenuBarSection {
        if let own = section(ofOwn: item) { return own }
        switch item.key {
        case .system(let module): return systemItems[module] ?? .shown
        case .identifier, .index: return section(ofApp: item.bundleID)
        }
    }

    /// The section whose list holds a spacer or a group's icon; nil for one that no list holds, and for anything that isn't one.
    public func section(ofOwn item: ItemID) -> MenuBarSection? {
        guard OwnItems.isOwn(item) else { return nil }
        return MenuBarSection.allCases.first { order[$0]?.contains(item) == true }
    }

    /// The icons in a section's list, in order: apps' icons, spacers and group icons. (A group's apps' icons are in `groupItems`.)
    public func items(in section: MenuBarSection) -> [ItemID] {
        order[section] ?? []
    }

    // MARK: Changing

    /// The person moves an app. It can't be moved back by Mantel afterwards (`isAuto` is cleared), and it leaves its group.
    public mutating func move(app bundleID: String, to section: MenuBarSection) {
        place(app: bundleID, in: section, isAuto: false)
    }

    /// The person moves an icon: its whole app, or for a system item the item itself. A spacer or a group's icon isn't moved this way
    /// (`insert` moves it): it has no app, and nothing is done for one, nor for any other item of the owner `mantel`.
    public mutating func move(item: ItemID, to section: MenuBarSection) {
        guard item.bundleID != OwnItems.owner else { return }
        switch item.key {
        case .system(let module):
            systemItems[module] = section
        case .identifier, .index:
            place(app: item.bundleID, in: section, isAuto: false)
        }
        // The icon is listed even if no scan has noted it yet.
        file([item], under: section)
    }

    /// The person drops an icon at a place in a section's list, between the icons there or at an end: a move to the section, and a
    /// reorder when it is the section it is in.
    ///
    /// - **An app's icon** takes the whole app with it: every icon the app has leaves every list (a group's too), and they are put at
    ///   `index` together and in the order they had. The app is then where the person put it (`isAuto` false) and in no group.
    /// - **A system item** moves alone.
    /// - **A spacer or a group's icon** moves alone, and a spacer or group this model doesn't have is left alone, as is any other item of
    ///   the owner `mantel`.
    ///
    /// `index` is a place among the icons the list has once the moved ones are out of it, and is brought into the list's length.
    public mutating func insert(_ item: ItemID, in section: MenuBarSection, at index: Int) {
        if OwnItems.isOwn(item) {
            guard knowsOwnItem(item) else { return }
            placeOwn(item, in: section, at: index)
            return
        }
        guard item.bundleID != OwnItems.owner else { return }
        let anchor = markerAnchor()
        let moving: [ItemID]
        switch item.key {
        case .system(let module):
            systemItems[module] = section
            moving = [item]
        case .identifier, .index:
            let listed = listedItems(ofApp: item.bundleID)
            moving = listed.contains(item) ? listed : listed + [item]
            leaveGroup(app: item.bundleID)
            apps[item.bundleID] = AppPlacement(section: section, isAuto: false)
        }
        let moved = removeFromLists(Set(moving))
        var list = order[section] ?? []
        list.insert(contentsOf: moving, at: min(max(index, 0), list.count))
        order[section] = list
        restoreMarker(anchor, moved: moved)
    }

    /// Gives each app that has no placement a place in `newItems`, as its own choice (`isAuto` false), and returns the apps it
    /// placed, in the order they were given. The ones that were placed already are left where they are.
    ///
    /// The caller gives the apps that have items in the menu bar (`Inventory.appsWithItems`): an app with none is never placed, and
    /// neither is `mantel`, which is the owner of Mantel's own items and no app.
    @discardableResult
    public mutating func assignNew(apps bundleIDs: [String]) -> [String] {
        var placed: [String] = []
        for bundleID in bundleIDs where apps[bundleID] == nil && bundleID != OwnItems.owner {
            apps[bundleID] = AppPlacement(section: newItems, isAuto: false)
            placed.append(bundleID)
        }
        return placed
    }

    /// Drops what is known of an app: its placement, its place in a group, and its icons from `order` and `groupItems`. It is placed
    /// again, in `newItems`, if it shows up again.
    public mutating func forget(app bundleID: String) {
        guard bundleID != OwnItems.owner else { return }
        let anchor = markerAnchor()
        leaveGroup(app: bundleID)
        apps[bundleID] = nil
        unchecked.remove(bundleID)
        let gone = Set(listedItems(ofApp: bundleID))
        guard !gone.isEmpty else { return }
        restoreMarker(anchor, moved: removeFromLists(gone))
    }

    /// Lists the icons that the layout editor doesn't know yet, and files each under its own section: an icon that is listed under
    /// another one is moved to its own.
    ///
    /// - **An app that has no icon listed yet** is a new one: its first icon is put at the marker (`newItemsIndex`), or at the end of the
    ///   list when the person never put it anywhere, and the marker moves past it, so apps that arrive one after another stay in the order
    ///   they came. (It is the section new apps go to that has the marker; an app the person had put elsewhere is listed at the end of
    ///   that section.)
    /// - **A later icon of an app** is listed right after that app's last icon in the section, so an app's icons stay together, whether
    ///   they arrive in one call, interleaved with other apps', or in later ones. (When the app has none in the section, at the end.)
    /// - **A system item** is listed at the end of its section.
    /// - **A grouped app's icons** are listed under its group (`groupItems`), after the icons of the members before it, and never in a
    ///   section's list.
    ///
    /// Mantel's own icons are left out: a spacer or a group's icon is in a list only because it was added (`addSpacer`, `addGroup`), and
    /// nothing of the owner `mantel` is an app's.
    public mutating func note(_ items: [MenuBarItem]) {
        noteIcons(items.filter { !$0.isMantel && $0.ownKind == nil && $0.id.bundleID != OwnItems.owner }.map(\.id))
    }

    /// `note`, for icons that are known to be an app's or a system item's. An app's icon that is named with one of Mantel's own names
    /// is refused: no other app has an item so called, and a record of one is a slot's name that was taken for the item's.
    public mutating func noteIcons(_ wanted: [ItemID]) {
        var seen: Set<ItemID> = []
        for id in wanted where seen.insert(id).inserted && !Self.namesAnOwnItem(id) {
            if id.isSystem {
                file([id], under: section(of: id))
            } else if let group = groupOf(app: id.bundleID) {
                file(inGroup: group, id)
            } else if listedItems(ofApp: id.bundleID).isEmpty, section(of: id) == newItems {
                listAtMarker(id)
            } else {
                file(id, nextToItsAppUnder: section(of: id))
            }
        }
    }

    /// Whether the icon is named as an item of Mantel's own is (a dot, the divider, a spacer, a group's icon) though it isn't Mantel's.
    public static func namesAnOwnItem(_ id: ItemID) -> Bool {
        guard id.bundleID != OwnItems.owner, case .identifier(let name) = id.key else { return false }
        return OwnItems.kind(name: name, description: nil) != nil
    }

    // MARK: Checking an app's records

    /// What `reconcile` did to an app's icons.
    public struct Reconciled: Sendable, Equatable {
        /// The records that are what the app lists, left where they were.
        public var kept: [ItemID] = []
        /// The records that aren't what the app lists, taken out.
        public var dropped: [ItemID] = []
        /// What the app lists that had no record: each took the place of a dropped one, or was listed as `note` lists it.
        public var added: [ItemID] = []

        public init(kept: [ItemID] = [], dropped: [ItemID] = [], added: [ItemID] = []) {
            self.kept = kept
            self.dropped = dropped
            self.added = added
        }
    }

    /// Checks an app's saved icons against what the app lists (`current`, from a whole read of it), and no longer holds it unchecked.
    ///
    /// - **A record that the app lists** stays where it is, in its section's list or its group's.
    /// - **An icon that the app lists and has no record** takes the place of the app's first record that isn't what it lists (the next of
    ///   them, the place of the next); when there is none, it is listed as `note` lists it.
    /// - **The other records** are taken out. Where the app is (`apps`), its group, the spacers, the other apps' icons and the system items
    ///   are not touched, and the marker stays before the icon it was before.
    @discardableResult
    public mutating func reconcile(app bundleID: String, current: [ItemID]) -> Reconciled {
        unchecked.remove(bundleID)
        guard bundleID != OwnItems.owner else { return Reconciled() }
        var seen: Set<ItemID> = []
        let now = current.filter { !$0.isSystem && $0.bundleID == bundleID && !Self.namesAnOwnItem($0) && seen.insert($0).inserted }
        let nowSet = Set(now)
        let records = listedItems(ofApp: bundleID)
        let recordSet = Set(records)
        var result = Reconciled(kept: records.filter(nowSet.contains), dropped: records.filter { !nowSet.contains($0) })
        var fresh = now.filter { !recordSet.contains($0) }
        guard !result.dropped.isEmpty else {
            noteIcons(fresh)
            result.added = fresh
            return result
        }
        let anchor = markerAnchor()
        let gone = Set(result.dropped)
        func rewritten(_ list: [ItemID]) -> [ItemID] {
            var out: [ItemID] = []
            for item in list {
                guard gone.contains(item) else {
                    out.append(item)
                    continue
                }
                if !fresh.isEmpty {
                    let next = fresh.removeFirst()
                    out.append(next)
                    result.added.append(next)
                }
            }
            return out
        }
        for section in MenuBarSection.allCases {
            guard let list = order[section] else { continue }
            let rewrittenList = rewritten(list)
            order[section] = rewrittenList.isEmpty ? nil : rewrittenList
        }
        for group in groupOrder + groupItems.keys.filter({ !groupOrder.contains($0) }).sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let list = groupItems[group] else { continue }
            let rewrittenList = rewritten(list)
            groupItems[group] = rewrittenList.isEmpty ? nil : rewrittenList
        }
        restoreMarker(anchor, moved: gone)
        noteIcons(fresh)
        result.added += fresh
        return result
    }

    /// Checks the unchecked apps among `apps` against the read's icons (`reconcile`), each from the icons the read has of it. Returns what
    /// was done to each app, in the order of their bundle IDs.
    public mutating func checkUnchecked(apps: Set<String>, in read: Inventory) -> [(app: String, done: Reconciled)] {
        var results: [(app: String, done: Reconciled)] = []
        for bundleID in apps.intersection(unchecked).sorted() {
            results.append((bundleID, reconcile(app: bundleID, current: read.items(ofApp: bundleID).map(\.id))))
        }
        return results
    }

    /// The icons that the places which list an app's icons leave out, because what the app lists now isn't known to have them.
    ///
    /// - An app that has been read whole in this run (`current`) has the icons of that read, and its other records are stale.
    /// - An app that hasn't, and that is unchecked (`unchecked`), has one record: the first that the latest read lists (`listed`), else its
    ///   first record. The others may be names it never had.
    /// - Any other app has every record.
    public func staleRecords(current: [String: Set<ItemID>], listed: [ItemID] = []) -> StaleRecords {
        let listedNow = Set(listed)
        var records: [String: [ItemID]] = [:]
        for id in allListedItems() where !id.isSystem && id.bundleID != OwnItems.owner && unchecked.contains(id.bundleID)
            && current[id.bundleID] == nil {
            records[id.bundleID, default: []].append(id)
        }
        var stale: Set<ItemID> = []
        for list in records.values {
            let shown = list.first(where: listedNow.contains) ?? list[0]
            stale.formUnion(list.filter { $0 != shown })
        }
        return StaleRecords(records: stale, current: current)
    }

    /// Puts a spacer in a section's list at `index` (brought into the list's length). The width is brought into 4 to 200. A spacer that
    /// is in a list already is moved there. One with an id that can't be an own item's (`OwnItems.isUsable`) is left out.
    public mutating func addSpacer(_ spacer: LayoutSpacer, in section: MenuBarSection, at index: Int) {
        guard OwnItems.isUsable(spacer.id) else { return }
        var stored = spacer
        stored.width = LayoutSpacer.clamped(width: spacer.width)
        spacers[spacer.id] = stored
        placeOwn(OwnItems.itemID(spacer.id), in: section, at: index)
    }

    /// Changes a spacer's width (brought into 4 to 200) or label. A spacer this model doesn't have is left alone.
    public mutating func updateSpacer(_ spacer: LayoutSpacer) {
        guard spacers[spacer.id] != nil else { return }
        var stored = spacer
        stored.width = LayoutSpacer.clamped(width: spacer.width)
        spacers[spacer.id] = stored
    }

    /// Puts a group's icon in a section's list at `index` (brought into the list's length), and its members in the group, in order. A
    /// group that is in the model already keeps the members it has, and its icon is moved there. One with an id that can't be an own
    /// item's (`OwnItems.isUsable`) is left out.
    public mutating func addGroup(_ group: IconGroup, in section: MenuBarSection, at index: Int) {
        guard OwnItems.isUsable(group.id) else { return }
        let existing = groups[group.id]
        var stored = group
        stored.members = existing?.members ?? []
        groups[group.id] = stored
        if !groupOrder.contains(group.id) { groupOrder.append(group.id) }
        placeOwn(OwnItems.itemID(group.id), in: section, at: index)
        guard existing == nil else { return }
        for (place, bundleID) in group.members.enumerated() {
            move(app: bundleID, toGroup: group.id, at: place)
        }
    }

    /// Changes a group's title, look and whether it opens on hover. Its members are changed by `move(app:toGroup:at:)`, and are the ones
    /// the model has whatever `group` says. A group this model doesn't have is left alone.
    public mutating func updateGroup(_ group: IconGroup) {
        guard let members = groups[group.id]?.members else { return }
        var stored = group
        stored.members = members
        groups[group.id] = stored
    }

    /// Takes a spacer or a group off the layout.
    ///
    /// - **A spacer** leaves its list and the model.
    /// - **A group** leaves with its icon. Its members stay in Always Hidden, no longer in a group, and their icons are put at the end
    ///   of Always Hidden's list in the order of the members.
    ///
    /// Anything else is left alone.
    public mutating func removeOwnItem(_ item: ItemID) {
        let anchor = markerAnchor()
        if let spacer = OwnItems.spacerID(of: item) {
            let moved = removeFromLists([item])
            spacers[spacer] = nil
            restoreMarker(anchor, moved: moved)
        } else if let group = OwnItems.groupID(of: item) {
            let moved = removeFromLists([item])
            if let stored = groups[group] {
                let released = groupItems[group] ?? []
                groupItems[group] = nil
                groups[group] = nil
                groupOrder.removeAll { $0 == group }
                for bundleID in stored.members where apps[bundleID]?.group == group {
                    apps[bundleID]?.group = nil
                }
                // The members' icons, in the order of the members (and any the members don't account for after them).
                let ofMembers = stored.members.flatMap { member in released.filter { $0.bundleID == member } }
                let ofOthers = released.filter { icon in !stored.members.contains(icon.bundleID) }
                var list = order[.alwaysHidden] ?? []
                var listed = Set(list)
                for icon in ofMembers + ofOthers where listed.insert(icon).inserted {
                    list.append(icon)
                }
                order[.alwaysHidden] = list.isEmpty ? nil : list
            }
            restoreMarker(anchor, moved: moved)
        }
    }

    /// Puts an app in a group: its section is Always Hidden, its icons leave the section lists and are put in the group's list after
    /// the icons of the members before it, and its bundle ID is put in the group's members at `index` (brought into the members'
    /// count). An app that is in a group already, this one included, leaves its place there first. A group this model doesn't have is
    /// left alone.
    public mutating func move(app bundleID: String, toGroup group: GroupID, at index: Int) {
        guard groups[group] != nil, bundleID != OwnItems.owner else { return }
        let anchor = markerAnchor()
        let items = listedItems(ofApp: bundleID)
        let moved = removeFromLists(Set(items))
        leaveGroup(app: bundleID)
        var members = groups[group]?.members ?? []
        let place = min(max(index, 0), members.count)
        members.insert(bundleID, at: place)
        groups[group]?.members = members
        apps[bundleID] = AppPlacement(section: .alwaysHidden, isAuto: false, group: group)

        var list = groupItems[group] ?? []
        let before = Set(members[..<place])
        let start = list.lastIndex { before.contains($0.bundleID) }.map { $0 + 1 } ?? 0
        list.insert(contentsOf: items, at: start)
        groupItems[group] = list.isEmpty ? nil : list
        restoreMarker(anchor, moved: moved)
    }

    /// Puts the marker for new apps in a section's list, before the icon at `index` (brought into the list's length); nil says the
    /// person never put it anywhere.
    public mutating func setNewItemsMarker(section: MenuBarSection, index: Int?) {
        newItems = section
        let count = order[section]?.count ?? 0
        newItemsIndex = index.map { min(max($0, 0), count) }
    }

    /// Puts an app in a section and its listed icons with it. Automatic overflow moves apps this way, without the person's say. An app
    /// leaves its group when it is moved to a section.
    mutating func place(app bundleID: String, in section: MenuBarSection, isAuto: Bool) {
        guard bundleID != OwnItems.owner else { return }
        leaveGroup(app: bundleID)
        apps[bundleID] = AppPlacement(section: section, isAuto: isAuto)
        file(listedItems(ofApp: bundleID), under: section)
    }

    // MARK: Groups

    /// The group an app is in, when the model has it.
    private func groupOf(app bundleID: String) -> GroupID? {
        guard let group = apps[bundleID]?.group, groups[group] != nil else { return nil }
        return group
    }

    /// Takes an app's bundle ID out of the members of the group it is in.
    private mutating func leaveGroup(app bundleID: String) {
        guard let group = apps[bundleID]?.group else { return }
        groups[group]?.members.removeAll { $0 == bundleID }
    }

    /// Lists an icon of a grouped app under its group, after the icons of the members before the app (and of the app). One that is
    /// listed there already stays, and one in a section's list leaves it.
    private mutating func file(inGroup group: GroupID, _ item: ItemID) {
        let anchor = markerAnchor()
        let listedHere = groupItems[group]?.contains(item) == true
        let moved = removeFromLists([item], keepingGroup: group)
        restoreMarker(anchor, moved: moved)
        guard !listedHere else { return }
        let members = groups[group]?.members ?? []
        var list = groupItems[group] ?? []
        let through: Set<String>
        if let place = members.firstIndex(of: item.bundleID) {
            through = Set(members[...place])
        } else {
            through = Set(members + [item.bundleID])
        }
        let place = list.lastIndex { through.contains($0.bundleID) }.map { $0 + 1 } ?? 0
        list.insert(item, at: place)
        groupItems[group] = list
    }

    // MARK: Own items

    /// Whether the model has the spacer or the group this identity names as its icon.
    private func knowsOwnItem(_ item: ItemID) -> Bool {
        if let spacer = OwnItems.spacerID(of: item) { return spacers[spacer] != nil }
        if let group = OwnItems.groupID(of: item) { return groups[group] != nil }
        return false
    }

    /// Puts an own item in a section's list at `index` (brought into the list's length), out of the list it was in.
    private mutating func placeOwn(_ item: ItemID, in section: MenuBarSection, at index: Int) {
        let anchor = markerAnchor()
        let moved = removeFromLists([item])
        var list = order[section] ?? []
        list.insert(item, at: min(max(index, 0), list.count))
        order[section] = list
        restoreMarker(anchor, moved: moved)
    }

    // MARK: The order lists

    /// Every icon the lists and the groups hold: the sections' lists in order, then the groups' (in `groupOrder`, then any other).
    private func allListedItems() -> [ItemID] {
        let others = groupItems.keys.filter { !groupOrder.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        return MenuBarSection.allCases.flatMap { order[$0] ?? [] } + (groupOrder + others).flatMap { groupItems[$0] ?? [] }
    }

    /// The records the model has of an app's icons, wherever they are listed.
    public func records(ofApp bundleID: String) -> [ItemID] {
        listedItems(ofApp: bundleID)
    }

    /// The icons of an app that the lists and the groups hold, whichever they are held in.
    /// The owner `mantel` has none: what it holds are Mantel's own items, which are no app's.
    private func listedItems(ofApp bundleID: String) -> [ItemID] {
        guard bundleID != OwnItems.owner else { return [] }
        return allListedItems().filter { $0.bundleID == bundleID && !$0.isSystem }
    }

    /// Takes `items` out of every list and every group's icons, except the section's list `section` and the group's icons `group` when
    /// they are given. A list left empty is dropped. What it returns are the icons it took out.
    @discardableResult
    private mutating func removeFromLists(_ items: Set<ItemID>, except section: MenuBarSection? = nil,
                                          keepingGroup group: GroupID? = nil) -> Set<ItemID> {
        var removed: Set<ItemID> = []
        for other in MenuBarSection.allCases where other != section {
            guard let list = order[other] else { continue }
            let kept = list.filter { !items.contains($0) }
            removed.formUnion(list.filter(items.contains))
            order[other] = kept.isEmpty ? nil : kept
        }
        for (key, list) in groupItems where key != group {
            let kept = list.filter { !items.contains($0) }
            removed.formUnion(list.filter(items.contains))
            groupItems[key] = kept.isEmpty ? nil : kept
        }
        return removed
    }

    /// Makes `section`'s list the only one that holds `items`: they leave every other list and every group, and join this one at the end
    /// unless they are in it already. A list left empty is dropped.
    private mutating func file(_ items: [ItemID], under section: MenuBarSection) {
        let anchor = markerAnchor()
        let moved = removeFromLists(Set(items), except: section)
        var list = order[section] ?? []
        var listed = Set(list)
        for item in items where listed.insert(item).inserted {
            list.append(item)
        }
        order[section] = list.isEmpty ? nil : list
        restoreMarker(anchor, moved: moved)
    }

    /// Makes `section`'s list the only one that holds `item`, an app's icon: it leaves every other list and every group, and joins this
    /// one right after the last icon of its app that is in it (at the end when none is), unless it is in it already.
    private mutating func file(_ item: ItemID, nextToItsAppUnder section: MenuBarSection) {
        let anchor = markerAnchor()
        let moved = removeFromLists([item], except: section)
        var list = order[section] ?? []
        if !list.contains(item) {
            let place = list.lastIndex { $0.bundleID == item.bundleID }.map { $0 + 1 } ?? list.count
            list.insert(item, at: place)
        }
        order[section] = list.isEmpty ? nil : list
        restoreMarker(anchor, moved: moved)
    }

    /// Lists an icon of a new app at the marker, and moves the marker past it. With no marker the icon goes to the end of the list.
    private mutating func listAtMarker(_ item: ItemID) {
        var list = order[newItems] ?? []
        let place = newItemsIndex.map { min(max($0, 0), list.count) } ?? list.count
        list.insert(item, at: place)
        order[newItems] = list
        if newItemsIndex != nil { newItemsIndex = place + 1 }
    }

    // MARK: The marker

    /// What follows the marker in its list: the icons it is before. A change to the list keeps it before the first of them that is
    /// still there (`restoreMarker`). Nil when there is no marker.
    private func markerAnchor() -> [ItemID]? {
        guard let index = newItemsIndex else { return nil }
        let list = order[newItems] ?? []
        return Array(list[min(max(index, 0), list.count)...])
    }

    /// Puts the marker back before the icon it was before, after a change to the lists. Icons that were taken out (`moved`) and put back
    /// somewhere else don't count: the marker stays where the icons that stayed are. When none of the icons it was before is left, it
    /// is at the end.
    private mutating func restoreMarker(_ anchor: [ItemID]?, moved: Set<ItemID>) {
        guard let anchor else { return }
        let list = order[newItems] ?? []
        if let neighbour = anchor.first(where: { !moved.contains($0) && list.contains($0) }), let place = list.firstIndex(of: neighbour) {
            newItemsIndex = place
        } else {
            newItemsIndex = list.count
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case apps, systemItems, order, newItems, spacers, groups, groupOrder, groupItems, newItemsIndex, unchecked
    }

    // A key missing from the file takes its default, so a file written before a key was added is still read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apps = try container.decodeIfPresent([String: AppPlacement].self, forKey: .apps) ?? [:]
        systemItems = try container.decodeIfPresent([String: MenuBarSection].self, forKey: .systemItems) ?? [:]
        order = try container.decodeIfPresent([MenuBarSection: [ItemID]].self, forKey: .order) ?? [:]
        newItems = try container.decodeIfPresent(MenuBarSection.self, forKey: .newItems) ?? .shown
        spacers = try container.decodeIfPresent([SpacerID: LayoutSpacer].self, forKey: .spacers) ?? [:]
        groups = try container.decodeIfPresent([GroupID: IconGroup].self, forKey: .groups) ?? [:]
        groupOrder = try container.decodeIfPresent([GroupID].self, forKey: .groupOrder) ?? []
        groupItems = try container.decodeIfPresent([GroupID: [ItemID]].self, forKey: .groupItems) ?? [:]
        newItemsIndex = try container.decodeIfPresent(Int.self, forKey: .newItemsIndex)
        unchecked = Set(try container.decodeIfPresent([String].self, forKey: .unchecked) ?? [])
    }

    // The apps that are unchecked are written in order, so that the file is the same on every run.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(apps, forKey: .apps)
        try container.encode(systemItems, forKey: .systemItems)
        try container.encode(order, forKey: .order)
        try container.encode(newItems, forKey: .newItems)
        try container.encode(spacers, forKey: .spacers)
        try container.encode(groups, forKey: .groups)
        try container.encode(groupOrder, forKey: .groupOrder)
        try container.encode(groupItems, forKey: .groupItems)
        try container.encodeIfPresent(newItemsIndex, forKey: .newItemsIndex)
        if !unchecked.isEmpty { try container.encode(unchecked.sorted(), forKey: .unchecked) }
    }
}

/// The records of icons that a place which lists icons leaves out (`SectionModel.staleRecords`).
public struct StaleRecords: Sendable, Equatable {
    /// The records of apps that haven't been read whole yet, that are not their first.
    let records: Set<ItemID>
    /// The icons of each app's last whole read in this run.
    let current: [String: Set<ItemID>]

    public static let none = StaleRecords(records: [], current: [:])

    init(records: Set<ItemID>, current: [String: Set<ItemID>]) {
        self.records = records
        self.current = current
    }

    /// Whether the icon is left out: its app was read whole and doesn't list it, or it is one of the records an unchecked app is held to.
    /// A system item, and an item of Mantel's own, is never.
    public func contains(_ id: ItemID) -> Bool {
        if id.isSystem || id.bundleID == OwnItems.owner { return false }
        if let now = current[id.bundleID] { return !now.contains(id) }
        return records.contains(id)
    }
}
