import CoreGraphics
import MKCore

/// The order macOS has the menu bar's items in, as it was read.
public struct ObservedOrder: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// Read from macOS's order table: every item that has a key.
        case table
        /// Read from a display's bar: only what is drawn there.
        case bar(displayUUID: String)
    }

    /// Left to right, as macOS has them.
    public let tokens: [LayoutToken]
    public let source: Source

    public init(tokens: [LayoutToken], source: Source) {
        self.tokens = tokens
        self.source = source
    }
}

/// Brings the sections up to date with the order macOS shows: what the person did by ⌘-dragging icons.
public enum LayoutFollower {
    /// How long the follow read waits after a ⌘-drag ends: macOS takes a moment to settle the icon it was holding into the order.
    public static let commandDragFollowDelay: Duration = .milliseconds(600)

    /// How long the follow waits before it reads again, when the read was empty or partial (`FollowTrust`): three more reads in all, the last
    /// 2.8 seconds after the drag's own wait. A drag that is still not followed then is left to the reads that come every few seconds.
    public static let commandDragRetryWaits: [Duration] = [.milliseconds(400), .milliseconds(800), .milliseconds(1600)]

    /// The follow starts no read after this long past the end of the drag, whatever the reads before it took: while it runs, clicks and
    /// pictures are refused ("being re-sorted"), and a read on a busy Mac takes seconds.
    public static let commandDragFollowLimit: Duration = .milliseconds(3500)

    /// Puts the icons of each list in the order macOS shows, and, when `sectionsMayChange`, moves an app that the person dragged across a
    /// boundary into the section it is now in.
    ///
    /// - **Order:** in each section's list (and each group's), the icons that are observed are put in the observed order, in the places
    ///   those icons held. An icon that isn't observed (a concealed one, on a bar read) keeps its place.
    /// - **Sections:** only for an app that moved (`before` is the observation taken when the drag began; with none, nothing changes
    ///   section). An app moved when it isn't in the longest run of apps that kept their order between `before` and `observed` (counting
    ///   the dots and the divider as places that stay), and it also crossed a dot or the divider that both observations hold, towards
    ///   the section it is now in. Passing an app, or being passed, never changes the side of a dot, so a drag within one side of the
    ///   dots changes no section, whatever the section the app was in. An app is where its left-most icon is.
    ///     - `.betweenSections`: left of •• is Always Hidden, between •• and • Hidden, right of • Shown. Without •• on the bar, left of
    ///       • is Hidden unless the app is Always Hidden. Without • nothing is told.
    ///     - `.besideClock`: left of the divider is Hidden unless the app is Always Hidden, right of it Shown. Without the divider nothing
    ///       is told.
    ///     - An app in a group, and Mantel's own items, never change section by a drag.
    public static func follow(_ sections: SectionModel, observed: ObservedOrder, placement: DotsPlacement, sectionsMayChange: Bool,
                              before: ObservedOrder?) -> SectionModel {
        var model = sections
        if sectionsMayChange, let before {
            moveSections(&model, observed: observed, before: before, placement: placement)
        }
        reorderLists(&model, observed: observed)
        return model
    }

    /// The order the table gives the tokens that have a key in it: the larger the distance, the further left.
    public static func observed(from table: LayoutTableSnapshot, resolution: LayoutKeyResolution) -> ObservedOrder {
        let placed = resolution.keys.compactMap { token, key in table.distances[key].map { (token: token, key: key, distance: $0) } }
        let sorted = placed.sorted { ($1.distance, $0.key) < ($0.distance, $1.key) }
        return ObservedOrder(tokens: sorted.map(\.token), source: .table)
    }

    /// The items drawn on the main display, as macOS has them: by their place on the bar. With `.lag` (an app's frames are behind the
    /// re-sort) it is by slot order, which is the order of the inventory's items, and only what a slot names: the items that name
    /// themselves, the dots and the divider. Spacers and groups' icons can't be told apart on a bar, and aren't in it.
    public static func observed(fromBar inventory: Inventory, frames: FramesAfterResort) -> ObservedOrder {
        guard let bar = mainBar(of: inventory) else { return ObservedOrder(tokens: [], source: .bar(displayUUID: "")) }
        let display = bar.displayUUID
        var drawn: [(token: LayoutToken, x: CGFloat)] = []
        for item in inventory.items {
            guard let token = LayoutToken.drawn(item), !item.overflowedOn.contains(display), let frame = item.frames[display] else { continue }
            if frames == .lag, !LayoutVerifier.namesItself(item) { continue }
            drawn.append((token, frame.midX))
        }
        if frames == .follow {
            drawn.sort { $0.x < $1.x }
        }
        return ObservedOrder(tokens: drawn.map(\.token), source: .bar(displayUUID: display))
    }

    // MARK: Order

    private static func reorderLists(_ model: inout SectionModel, observed: ObservedOrder) {
        var place: [LayoutToken: Int] = [:]
        for (index, token) in observed.tokens.enumerated() where place[token] == nil { place[token] = index }

        func reordered(_ list: [ItemID]) -> [ItemID] {
            let slots = list.indices.filter { place[.item(list[$0])] != nil }
            let inOrder = slots.map { list[$0] }.sorted { place[.item($0)]! < place[.item($1)]! }
            var result = list
            for (slot, item) in zip(slots, inOrder) { result[slot] = item }
            return result
        }
        for (section, list) in model.order {
            let updated = reordered(list)
            if updated != list { model.order[section] = updated }
        }
        for (group, list) in model.groupItems {
            let updated = reordered(list)
            if updated != list { model.groupItems[group] = updated }
        }
    }

    // MARK: Sections

    private enum Element: Hashable {
        case app(String)
        case anchor(LayoutToken)
    }

    /// The apps (by their left-most icon), the dots and the divider, left to right.
    private static func elements(_ observed: ObservedOrder) -> [Element] {
        var seen: Set<Element> = []
        var result: [Element] = []
        for token in observed.tokens {
            let element: Element
            switch token {
            case .item(let id):
                if id.isSystem || id.bundleID == OwnItems.owner { continue }
                element = .app(id.bundleID)
            case .dot, .divider:
                element = .anchor(token)
            }
            if seen.insert(element).inserted { result.append(element) }
        }
        return result
    }

    private static func moveSections(_ model: inout SectionModel, observed: ObservedOrder, before: ObservedOrder, placement: DotsPlacement) {
        let now = elements(observed)
        let then = elements(before)
        let common = Set(now).intersection(then)
        let kept = longestKeptRun(then.filter(common.contains), now.filter(common.contains))

        let anchors = then.filter { if case .anchor = $0 { common.contains($0) } else { false } }
        /// For each anchor both observations hold, whether the element is left of it (none when the list doesn't have the element).
        func sides(of element: Element, in list: [Element]) -> [Bool] {
            guard let at = list.firstIndex(of: element) else { return [] }
            return anchors.map { anchor in list.firstIndex(of: anchor).map { at < $0 } ?? false }
        }
        func rank(_ section: MenuBarSection) -> Int {
            switch section {
            case .alwaysHidden: 0
            case .hidden: 1
            case .shown: 2
            }
        }

        func place(_ token: LayoutToken) -> Int? { now.firstIndex(of: .anchor(token)) }
        for (index, element) in now.enumerated() {
            guard case .app(let bundleID) = element, common.contains(element), !kept.contains(element) else { continue }
            let wasLeft = sides(of: element, in: then)
            let isLeft = sides(of: element, in: now)
            // A crossing to the right of an anchor (left of it, then not) or to the left of one.
            let crossedRight = zip(wasLeft, isLeft).contains { $0 && !$1 }
            let crossedLeft = zip(wasLeft, isLeft).contains { !$0 && $1 }
            // An early way out: the direction check below holds only after a crossing.
            guard crossedRight || crossedLeft else { continue }
            guard model.apps[bundleID]?.group == nil else { continue }
            let current = model.section(ofApp: bundleID)
            let target: MenuBarSection
            switch placement {
            case .betweenSections:
                guard let hidden = place(.dot(.hidden)) else { continue }
                if let always = place(.dot(.always)), index < always {
                    target = .alwaysHidden
                } else if index < hidden {
                    target = place(.dot(.always)) == nil && current == .alwaysHidden ? .alwaysHidden : .hidden
                } else {
                    target = .shown
                }
            case .besideClock:
                guard let divider = place(.divider) else { continue }
                target = index < divider ? (current == .alwaysHidden ? .alwaysHidden : .hidden) : .shown
            }
            guard target != current else { continue }
            // The way it crossed has to be the way the section changes.
            if rank(target) > rank(current) ? crossedRight : crossedLeft { model.move(app: bundleID, to: target) }
        }
    }

    /// The elements of the longest run both orders have in common, with the dots and the divider worth more than all the apps together, so
    /// that they are always part of it when they can be.
    private static func longestKeptRun(_ a: [Element], _ b: [Element]) -> Set<Element> {
        func weight(_ element: Element) -> Int {
            if case .anchor = element { return a.count + b.count + 1 }
            return 1
        }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in a.indices.reversed() {
            for j in b.indices.reversed() {
                table[i][j] = a[i] == b[j] ? weight(a[i]) + table[i + 1][j + 1] : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var kept: Set<Element> = []
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                kept.insert(a[i])
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return kept
    }

    // MARK: The bar

    /// The main display's bar: the one at the origin of the global space, else the first.
    private static func mainBar(of inventory: Inventory) -> MenuBarGeometry? {
        inventory.bars.first { $0.rect.origin == .zero } ?? inventory.bars.first
    }
}
