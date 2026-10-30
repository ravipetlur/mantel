import MKCore

/// Which of Mantel's own items are on the menu bar as things stand: the dots, the divider, and each spacer and group icon. An item that is
/// off the bar is taken off it by Mantel itself (`OwnItemHiding`); nothing about it is written to the order table.
public struct OwnItemsShown: Sendable, Equatable {
    public var hiddenDot: Bool
    public var alwaysDot: Bool
    public var divider: Bool
    public var spacers: Set<SpacerID>
    public var groups: Set<GroupID>

    public init(hiddenDot: Bool = false, alwaysDot: Bool = false, divider: Bool = false, spacers: Set<SpacerID> = [],
                groups: Set<GroupID> = []) {
        self.hiddenDot = hiddenDot
        self.alwaysDot = alwaysDot
        self.divider = divider
        self.spacers = spacers
        self.groups = groups
    }
}

/// A spacer or a group's icon: one of the own items the layout holds, apart from the dots and the divider.
public enum OwnItemRef: Sendable, Equatable {
    case spacer(SpacerID)
    case group(GroupID)
}

/// What decides whether each of Mantel's own items is on the bar.
public enum OwnItemsVisibility {
    /// - **The dots:** • unless both are hidden; •• too when the person set it to always, or when Always Hidden holds an app that is
    ///   running (a grouped app counts: it is in Always Hidden).
    /// - **The divider:** when the person turned it on.
    /// - **A spacer or a group's icon:** when its section isn't one the plan conceals, so a spacer in Hidden is on the bar exactly while
    ///   the apps of Hidden are. One that no section holds isn't drawn.
    /// - **Focus Mode:** only the dots.
    ///
    /// - Parameters:
    ///   - plan: what the bar is asked to show now.
    ///   - alwaysHiddenHasApps: whether anything that is running is in Always Hidden (`MenuBarState.alwaysHiddenHasApps`).
    public static func shown(sections: SectionModel, plan: VisibilityPlan, dots: DotSettings, alwaysHiddenHasApps: Bool) -> OwnItemsShown {
        var shown = beforeTheFirstRead(dots: dots)
        shown.alwaysDot = !dots.hideBothDots && (dots.alwaysDot == .always || alwaysHiddenHasApps)
        guard plan.source != .focusMode else { return shown }
        shown.divider = dots.showsDivider
        func isOnBar(_ item: ItemID) -> Bool {
            guard let section = sections.section(ofOwn: item) else { return false }
            return !plan.concealedSections.contains(section)
        }
        shown.spacers = Set(sections.spacers.keys.filter { isOnBar(OwnItems.itemID($0)) })
        shown.groups = Set(sections.groups.keys.filter { isOnBar(OwnItems.itemID($0)) })
        return shown
    }

    /// What is on the bar before the session has said anything: the dots as the settings have them, and nothing else.
    public static func beforeTheFirstRead(dots: DotSettings) -> OwnItemsShown {
        OwnItemsShown(hiddenDot: !dots.hideBothDots, alwaysDot: !dots.hideBothDots && dots.alwaysDot == .always)
    }

    /// The spacers and groups in the order their status items are made: each section's list in order, with a spacer or a group's icon
    /// where the list has it; then the groups in `groupOrder`, and last any a list doesn't hold (by name). Each once, and only those the
    /// layout holds, and that `OwnItems` can name: an id it refuses (a hand-made `divider`, which the wide spacer's invisible item goes by)
    /// has no status item, for it would share its place and visibility with that item's.
    public static func creationOrder(_ sections: SectionModel) -> [OwnItemRef] {
        var order: [OwnItemRef] = []
        var seenSpacers: Set<SpacerID> = []
        var seenGroups: Set<GroupID> = []
        for section in MenuBarSection.allCases {
            for item in sections.items(in: section) {
                if let id = OwnItems.spacerID(of: item), sections.spacers[id] != nil, seenSpacers.insert(id).inserted {
                    order.append(.spacer(id))
                } else if let id = OwnItems.groupID(of: item), sections.groups[id] != nil, seenGroups.insert(id).inserted {
                    order.append(.group(id))
                }
            }
        }
        for id in sections.groupOrder where sections.groups[id] != nil && OwnItems.isUsable(id) && seenGroups.insert(id).inserted {
            order.append(.group(id))
        }
        for id in sections.groups.keys.sorted(by: { $0.rawValue < $1.rawValue }) where OwnItems.isUsable(id) && seenGroups.insert(id).inserted {
            order.append(.group(id))
        }
        for id in sections.spacers.keys.sorted(by: { $0.rawValue < $1.rawValue }) where OwnItems.isUsable(id) && seenSpacers.insert(id).inserted {
            order.append(.spacer(id))
        }
        return order
    }
}
