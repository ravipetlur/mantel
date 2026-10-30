import CoreGraphics
import MKCore
import MKLayout

/// What the tests of the arrangement, the keys, the follower and the verifier share.
enum ArrangementFixtures {
    static let ownBundle = "com.example.mantel"

    static func app(_ name: String, _ identifier: String = "main") -> ItemID {
        Fixtures.itemID("com.example.\(name)", identifier)
    }

    static func nameless(_ name: String, _ index: Int = 0) -> ItemID {
        ItemID(bundleID: "com.example.\(name)", key: .index(index))
    }

    /// Sections with these icons in their lists, and their apps placed there.
    static func sections(always: [ItemID] = [], hidden: [ItemID] = [], shown: [ItemID] = []) -> SectionModel {
        var model = SectionModel()
        for (section, items) in [(MenuBarSection.alwaysHidden, always), (.hidden, hidden), (.shown, shown)] where !items.isEmpty {
            model.order[section] = items
            for item in items where !item.isSystem && !OwnItems.isOwn(item) {
                model.apps[item.bundleID] = AppPlacement(section: section, isAuto: false)
            }
        }
        return model
    }

    static func inputs(_ sections: SectionModel, placement: DotsPlacement = .betweenSections, alwaysDot: Bool = true, dots: Bool = true,
                       divider: Bool = true, widths: [ItemID: CGFloat] = [:]) -> LayoutInputs {
        LayoutInputs(sections: sections, placement: placement, alwaysDotShown: alwaysDot, dotsShown: dots, dividerShown: divider, widths: widths)
    }

    static func rules(_ reference: DistanceReference = .orderOnly, needsKnownWidths: Bool = false) -> LayoutRules {
        var rules = LayoutRules.measured
        rules.reference = reference
        rules.needsKnownWidths = needsKnownWidths
        return rules
    }

    static func bar(_ display: String = Fixtures.display, width: CGFloat = 1000) -> MenuBarGeometry {
        MenuBarGeometry(displayUUID: display, rect: CGRect(x: 0, y: 0, width: width, height: 24), notch: nil)
    }

    /// An app's item drawn at `x` on a display.
    static func drawn(_ id: ItemID, x: CGFloat, width: CGFloat = 30, display: String = Fixtures.display, overflowed: Bool = false) -> MenuBarItem {
        MenuBarItem(id: id, ownerBundleID: id.bundleID, appName: nil, label: nil,
                    frames: [display: CGRect(x: x, y: 0, width: width, height: 24)], overflowedOn: overflowed ? [display] : [], isMantel: false)
    }

    static func concealed(_ id: ItemID) -> MenuBarItem {
        Fixtures.item(id)
    }

    /// One of Mantel's own items as the inventory has it: the real bundle ID, and a name of its own.
    static func own(_ kind: OwnItemKind, x: CGFloat?, name: String? = nil, display: String = Fixtures.display) -> MenuBarItem {
        let autosave = name ?? {
            switch kind {
            case .hiddenDot: OwnItems.hiddenDotName
            case .alwaysDot: OwnItems.alwaysDotName
            case .divider: OwnItems.dividerName
            case .spacer: "mantel.spacer.0000abcd"
            case .group: "mantel.group.0000abcd"
            }
        }()
        return MenuBarItem(id: ItemID(bundleID: ownBundle, key: .identifier(autosave)), ownerBundleID: ownBundle, appName: nil, label: nil,
                           frames: x.map { [display: CGRect(x: $0, y: 0, width: 12, height: 24)] } ?? [:], overflowedOn: [],
                           isMantel: true, ownKind: kind)
    }

    static func inventory(_ items: [MenuBarItem], bars: [MenuBarGeometry]? = nil) -> Inventory {
        Fixtures.inventory(items, bars: bars ?? [bar()])
    }

    /// An inventory whose slots are the frames its items have, left to right on each display (what the matcher's tie leaves), unless
    /// `slots` says what a display's slots are. `contested` is the apps whose places aren't to be believed.
    static func slotted(_ items: [MenuBarItem], bars: [MenuBarGeometry]? = nil, slots: [String: [CGRect]]? = nil,
                        contested: Set<String> = []) -> Inventory {
        let bars = bars ?? [bar()]
        var barSlots: [String: [BarSlot]] = [:]
        for bar in bars {
            let frames = slots?[bar.displayUUID] ?? items.compactMap { item in
                item.overflowedOn.contains(bar.displayUUID) ? nil : item.frames[bar.displayUUID]
            }.sorted { $0.minX < $1.minX }
            barSlots[bar.displayUUID] = frames.map { BarSlot(frame: $0, name: nil) }
        }
        return Inventory(capturedAt: Fixtures.date(0), bars: bars, items: items, chevrons: [:], reach: [], problems: [],
                         barSlots: barSlots, contestedApps: contested)
    }

    static func table(_ entries: [String: Double]) -> LayoutTableSnapshot {
        LayoutTableSnapshot(distances: entries)
    }

    static func key(_ id: ItemID) -> String {
        guard case .identifier(let name) = id.key else { return "" }
        return LayoutKey.status(bundleID: id.bundleID, autosaveName: name)
    }

    static func ownKey(_ name: String) -> String {
        LayoutKey.status(bundleID: ownBundle, autosaveName: name)
    }
}
