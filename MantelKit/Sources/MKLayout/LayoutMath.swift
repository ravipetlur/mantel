import CoreGraphics
import MKCore

/// One place in the arrangement: an app's or Mantel's own item, a dot, or the divider.
public enum LayoutToken: Hashable, Sendable {
    case item(ItemID)
    case dot(DotKind)
    case divider

    /// The token a drawn item of the inventory stands for. Nil for a system item, for a spacer or a group's icon (they can't be told apart
    /// on the bar), and for an item of Mantel's that is none of Mantel's kinds.
    public static func drawn(_ item: MenuBarItem) -> LayoutToken? {
        if let kind = item.ownKind {
            switch kind {
            case .hiddenDot: return .dot(.hidden)
            case .alwaysDot: return .dot(.always)
            case .divider: return .divider
            case .spacer, .group: return nil
            }
        }
        if item.isMantel || item.id.isSystem { return nil }
        return .item(item.id)
    }
}

/// What the arrangement is made of.
public struct LayoutInputs: Sendable, Equatable {
    public var sections: SectionModel
    public var placement: DotsPlacement
    /// •• is on the bar (it is there only while a section has apps that need it).
    public var alwaysDotShown: Bool
    /// The dots are on the bar at all.
    public var dotsShown: Bool
    public var dividerShown: Bool
    /// Slot widths; an own item's is its length.
    public var widths: [ItemID: CGFloat]

    public init(sections: SectionModel, placement: DotsPlacement, alwaysDotShown: Bool, dotsShown: Bool, dividerShown: Bool,
                widths: [ItemID: CGFloat]) {
        self.sections = sections
        self.placement = placement
        self.alwaysDotShown = alwaysDotShown
        self.dotsShown = dotsShown
        self.dividerShown = dividerShown
        self.widths = widths
    }
}

/// The order the menu bar should have, and a distance for each place in it.
public struct LayoutArrangement: Sendable, Equatable {
    /// Left to right. Never a system item: macOS keeps those where they are.
    public let tokens: [LayoutToken]
    public let distances: [LayoutToken: Double]
    /// Items that have no distance because their width is unknown (and the rules need it). They keep their place in `tokens`.
    public let skipped: [ItemID]

    public init(tokens: [LayoutToken], distances: [LayoutToken: Double], skipped: [ItemID]) {
        self.tokens = tokens
        self.distances = distances
        self.skipped = skipped
    }
}

/// The math that turns sections into an order and distances.
public enum LayoutMath {
    /// What an item takes when its width isn't known.
    public static let assumedWidth: CGFloat = 38
    public static let dividerWidth: CGFloat = 9

    /// The arrangement of the sections, left to right.
    ///
    /// - `.betweenSections`: the groups' icons, Always Hidden, ••, Hidden, •, the divider, Shown.
    /// - `.besideClock`: the groups' icons, Always Hidden, Hidden, the divider, Shown, ••, •.
    /// - What is left out: every system item; the dots when they aren't shown, and •• when it isn't; the divider when it isn't.
    ///
    /// A distance is `systemStart` plus the widths of the tokens to the token's right (`.leftEdge` adds the token's own), rounded to 0.5.
    /// The dots are `assumedWidth` wide. `rules` gives the reference and whether an item of unknown width is skipped: it has no distance,
    /// and the items to its left are placed as if it were `assumedWidth` wide. `systemStart` is where the apps' items begin: to the left
    /// of every system item.
    public static func arrange(_ inputs: LayoutInputs, rules: LayoutRules, systemStart: Double) -> LayoutArrangement {
        let tokens = orderedTokens(inputs)
        var distances: [LayoutToken: Double] = [:]
        var skipped: [ItemID] = []
        var toTheRight = systemStart
        for token in tokens.reversed() {
            let known = knownWidth(of: token, inputs.widths)
            let width = known ?? assumedWidth
            if rules.needsKnownWidths, known == nil {
                if case .item(let id) = token { skipped.append(id) }
            } else {
                let distance = rules.reference == .leftEdge ? toTheRight + Double(width) : toTheRight
                distances[token] = roundedToHalf(distance)
            }
            toTheRight += Double(width)
        }
        return LayoutArrangement(tokens: tokens, distances: distances, skipped: skipped.reversed())
    }

    /// Where the apps' items begin: the largest distance among the system modules that are drawn, plus that module's width. `presentModules`
    /// is the drawn modules by their name in the inventory, each with its name in the table (`LayoutKey.presentModules(in:table:)`). 0 when none
    /// is drawn: a module the Mac doesn't draw can hold a distance far to the left.
    public static func systemStart(table: LayoutTableSnapshot, presentModules: [String: String], widths: [ItemID: CGFloat]) -> Double {
        var start = 0.0
        for (module, keyName) in presentModules {
            guard let distance = table.distances["module:" + keyName] else { continue }
            let width = widths[.system(module)] ?? assumedWidth
            start = max(start, distance + Double(width))
        }
        return start
    }

    /// The distance of the left-most module that is drawn and stays (the clock, Wi‑Fi, Battery and the like; not the ones that come and go,
    /// `LayoutKey.comingAndGoingModules`, by its name in the inventory or in the table): an app with a key at or below it sits among the
    /// modules that stay. A module's own distance is where it begins, and an app left of it has at least that distance plus the module's
    /// width, so no width estimate enters. 0 when none of them is drawn.
    public static func stayingModulesStart(table: LayoutTableSnapshot, presentModules: [String: String]) -> Double {
        let comingAndGoingKeyNames = Set(LayoutKey.comingAndGoingModules.compactMap { LayoutKey.moduleKeyNames[$0] })
        var start = 0.0
        for (module, keyName) in presentModules
        where !LayoutKey.comingAndGoingModules.contains(module) && !comingAndGoingKeyNames.contains(keyName) {
            if let distance = table.distances["module:" + keyName] { start = max(start, distance) }
        }
        return start
    }

    // MARK: Order

    private static func orderedTokens(_ inputs: LayoutInputs) -> [LayoutToken] {
        let sections = inputs.sections
        let others = sections.groupItems.keys.filter { !sections.groupOrder.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        let grouped = (sections.groupOrder + others).flatMap { sections.groupItems[$0] ?? [] }
        func items(_ ids: [ItemID]) -> [LayoutToken] {
            ids.filter { !$0.isSystem }.map(LayoutToken.item)
        }
        let alwaysDot: [LayoutToken] = inputs.dotsShown && inputs.alwaysDotShown ? [.dot(.always)] : []
        let hiddenDot: [LayoutToken] = inputs.dotsShown ? [.dot(.hidden)] : []
        let divider: [LayoutToken] = inputs.dividerShown ? [.divider] : []
        let alwaysList = items(sections.items(in: .alwaysHidden))
        let hiddenList = items(sections.items(in: .hidden))
        let shownList = items(sections.items(in: .shown))
        switch inputs.placement {
        case .betweenSections:
            return items(grouped) + alwaysList + alwaysDot + hiddenList + hiddenDot + divider + shownList
        case .besideClock:
            return items(grouped) + alwaysList + hiddenList + divider + shownList + alwaysDot + hiddenDot
        }
    }

    private static func knownWidth(of token: LayoutToken, _ widths: [ItemID: CGFloat]) -> CGFloat? {
        switch token {
        case .item(let id): widths[id]
        case .dot: assumedWidth
        case .divider: dividerWidth
        }
    }

    private static func roundedToHalf(_ value: Double) -> Double {
        (value * 2).rounded() / 2
    }
}
