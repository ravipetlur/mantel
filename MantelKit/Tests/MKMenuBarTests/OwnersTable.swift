import CoreGraphics
import Foundation
import MKCore
import MKLayout

@testable import MKMenuBar

/// A read of one real Mac's menu bar and of its order table, with every bundle ID replaced by a made-up one.
/// The table is the one a write started from (macOS's own copy, before anything of Mantel's was written); the bar, the sections and the
/// apps' items are from a later read of the same Mac, so an app that was running then and isn't now has keys and no item, and an app that is
/// listed in the sections and isn't running has neither.
enum OwnersTable {
    static let own = "com.example.mantel"
    static let testItem = "com.example.mantel.testitem"
    static let main = "MAIN"
    static let second = "SECOND"
    static let mainBar = CGRect(x: 0, y: 0, width: 3840, height: 30)
    static let secondBar = CGRect(x: -1800, y: -221, width: 1800, height: 30)
    static let distances: [String: Double] = [
        "module:AirDrop": 895.0,
        "module:AudioVideoModule": 829.0,
        "module:Battery": 177.0,
        "module:BentoBox-0": 129.0,
        "module:Bluetooth": 321.0,
        "module:Clock": 0.0,
        "module:Display": 145.0,
        "module:FocusModes": 153.0,
        "module:NowPlaying": 662.5,
        "module:ScreenMirroring": 628.5,
        "module:Sound": 299.0,
        "module:WiFi": 155.0,
        "status:com.apple.TextInputMenuAgent::Item-0": 679.0,
        "status:com.apple.campo::Item-0": 253.0,
        "status:com.apple.systemuiserver::Siri": 128.5,
        "status:com.apple.systemuiserver::com.apple.menuextra.TimeMachine": 857.0,
        "status:com.apple.systemuiserver::com.apple.menuextra.vpn": 781.0,
        "status:com.apple.weather.menu::Item-0": 267.0,
        "status:com.example.app01::Item-0": 524.0,
        "status:com.example.app01::Item-1": 626.0,
        "status:com.example.app01::Item-2": 658.0,
        "status:com.example.app01::Item-3": 709.0,
        "status:com.example.app03::Item-0": 383.0,
        "status:com.example.app04::name8": 912.5,
        "status:com.example.app05::3d1f6a52-0b7e-4c19-9a4d-5e2c8f7b1a60": 298.0,
        "status:com.example.app06::/Users/example/scripts/script4.sh": 687.0,
        "status:com.example.app06::/Users/example/scripts/script5.sh": 655.0,
        "status:com.example.app06::/Users/example/scripts/script9.sh": 413.0,
        "status:com.example.app07::Item-0": 494.0,
        "status:com.example.app08::name1": 434.0,
        "status:com.example.app08::name10": 466.0,
        "status:com.example.app08::name11": 502.0,
        "status:com.example.app10::Item-0": 522.5,
        "status:com.example.app11::Item-0": 632.5,
        "status:com.example.app12::Item-0": 714.0,
        "status:com.example.app13::Item-0": 506.0,
        "status:com.example.app14::Item-0": 456.0,
        "status:com.example.app16::name6": 203.0,
        "status:com.example.app17::Item-0": 444.0,
        "status:com.example.app18::Item-0": 375.0,
        "status:com.example.app20::Item-0": 454.0,
        "status:com.example.app20::name12": 554.5,
        "status:com.example.app21::name13": 468.0,
        "status:com.example.app21::name3": 435.0,
        "status:com.example.app22::Item-0": 404.5,
        "status:com.example.app23::name2": 258.0,
        "status:com.example.app24::c91e47b8-2f03-4d6a-b5e9-17a0d3c68f42": 871.0,
        "status:com.example.app25::name7": 442.5,
        "status:com.example.app26::Item-0": 464.0,
        "status:com.example.app27::Item-0": 670.5,
        "status:com.example.app28::Item-0": 747.0,
        "status:com.example.app30::Item-0": 752.0,
        "status:com.example.app31::Item-0": 336.0,
        "status:com.example.app32::Item-0": 669.0,
        "status:com.example.app33::Item-0": 337.0,
        "status:com.example.app36::Item-0": 427.0,
        "status:com.example.app37::Item-0": 238.0,
        "status:com.example.mantel.testitem::mantel.fixture.extra.1": 934.5,
        "status:com.example.mantel.testitem::mantel.fixture.extra.10": 1338.5,
        "status:com.example.mantel.testitem::mantel.fixture.extra.11": 1377.5,
        "status:com.example.mantel.testitem::mantel.fixture.extra.12": 1439.5,
        "status:com.example.mantel.testitem::mantel.fixture.extra.2": 976.5,
        "status:com.example.mantel.testitem::mantel.fixture.extra.3": 182.5,
        "status:com.example.mantel.testitem::mantel.fixture.extra.4": 1020.5,
        "status:com.example.mantel.testitem::mantel.fixture.extra.5": 1068.5,
        "status:com.example.mantel.testitem::mantel.fixture.extra.6": 1118.5,
        "status:com.example.mantel.testitem::mantel.fixture.extra.7": 1170.5,
        "status:com.example.mantel.testitem::mantel.fixture.extra.8": 1224.5,
        "status:com.example.mantel.testitem::mantel.fixture.extra.9": 1280.5,
        "status:com.example.mantel.testitem::mantel.fixture.one": 896.5,
        "status:com.example.mantel.testitem::mantel.fixture.two": 839.0,
        "status:com.example.mantel::mantel.dot.always": 631.0,
        "status:com.example.mantel::mantel.dot.hidden": 593.0,
        "status:com.example.mantel::mantel.spacer.always": 877.0,
        "status:com.example.mantel::mantel.spacer.divider": 829.0,
        "status:com.example.mantel::mantel.spacer.divider.2": 845.0,
        "status:com.example.mantel::mantel.spacer.divider.3": 775.0,
        "status:com.example.mantel::mantel.spacer.divider.4": 861.0,
    ]
    /// The saved sections, as a profile's JSON.
    static let sectionsJSON = """
{"apps": {"com.apple.TextInputMenuAgent": {"isAuto": false, "section": "hidden"}, "com.apple.systemuiserver": {"isAuto": false, "section": "hidden"}, "com.example.app01": {"isAuto": false, "section": "shown"}, "com.example.app02": {"isAuto": false, "section": "shown"}, "com.example.app05": {"isAuto": false, "section": "hidden"}, "com.example.app06": {"isAuto": false, "section": "shown"}, "com.example.app07": {"isAuto": false, "section": "hidden"}, "com.example.app09": {"isAuto": false, "section": "shown"}, "com.example.app10": {"isAuto": false, "section": "shown"}, "com.example.app12": {"isAuto": false, "section": "hidden"}, "com.example.app13": {"isAuto": false, "section": "shown"}, "com.example.app15": {"isAuto": false, "section": "shown"}, "com.example.app16": {"isAuto": false, "section": "shown"}, "com.example.app17": {"isAuto": false, "section": "hidden"}, "com.example.app18": {"isAuto": false, "section": "hidden"}, "com.example.app19": {"isAuto": false, "section": "shown"}, "com.example.app20": {"isAuto": false, "section": "alwaysHidden"}, "com.example.app22": {"isAuto": false, "section": "shown"}, "com.example.app24": {"isAuto": false, "section": "hidden"}, "com.example.app25": {"isAuto": false, "section": "shown"}, "com.example.app27": {"isAuto": false, "section": "shown"}, "com.example.app28": {"isAuto": false, "section": "shown"}, "com.example.app29": {"isAuto": false, "section": "shown"}, "com.example.app30": {"isAuto": false, "section": "hidden"}, "com.example.app33": {"isAuto": false, "section": "shown"}, "com.example.app34": {"isAuto": false, "section": "shown"}, "com.example.app35": {"isAuto": false, "section": "shown"}, "com.example.app36": {"isAuto": false, "section": "shown"}, "com.example.app37": {"isAuto": false, "section": "shown"}, "com.example.mantel.testitem": {"isAuto": false, "section": "hidden"}}, "groupItems": {}, "groupOrder": [], "groups": {}, "newItems": "shown", "order": {"alwaysHidden": ["com.example.app20#0"], "hidden": ["com.example.app05#0", "com.example.app17#0", "com.example.app07#0", "com.example.mantel.testitem::mantel.fixture.extra.12", "com.example.mantel.testitem::mantel.fixture.extra.11", "com.example.mantel.testitem::mantel.fixture.extra.10", "com.example.mantel.testitem::mantel.fixture.extra.9", "com.example.mantel.testitem::mantel.fixture.extra.8", "com.example.mantel.testitem::mantel.fixture.extra.7", "com.example.mantel.testitem::mantel.fixture.extra.6", "com.example.mantel.testitem::mantel.fixture.extra.5", "com.example.mantel.testitem::mantel.fixture.extra.4", "com.example.mantel.testitem::mantel.fixture.extra.2", "com.example.mantel.testitem::mantel.fixture.extra.1", "com.example.mantel.testitem::mantel.fixture.two", "com.example.app30#0", "com.example.mantel.testitem::mantel.fixture.one", "com.apple.systemuiserver#0", "com.apple.systemuiserver#1", "com.example.app24#0", "com.example.app18#0", "com.apple.TextInputMenuAgent#0", "com.example.app12#0", "com.example.mantel.testitem::mantel.fixture.extra.3", "com.apple.systemuiserver#2"], "shown": ["system:airdrop", "system:bluetooth", "system:sound", "system:battery", "system:controlcenter", "com.example.app35#0", "system:audiovideo", "com.example.app36#0", "system:clock", "com.example.app25#0", "com.example.app37#0", "com.example.app01#0", "com.example.app01#1", "com.example.app01#2", "com.example.app01#3", "com.example.app10#0", "com.example.app15#0", "com.example.app13#0", "com.example.app27#0", "com.example.app27::name14", "com.example.app02#0", "system:now-playing", "com.example.app34#0", "com.example.app34#1", "com.example.app25::name15", "com.example.app27::name16", "com.example.app29#0", "com.example.app29#1", "com.example.app09#0", "system:wifi", "com.example.app22#0", "com.example.app19#0", "com.example.app33#0", "com.example.app06#0", "com.example.app16#0", "com.example.app28#0", "com.example.app06#1"]}, "spacers": {}, "systemItems": {"bluetooth": "shown", "clock": "shown", "wifi": "shown"}, "unchecked": ["com.example.app29", "com.example.app01", "com.example.app02", "com.example.app09", "com.example.app10", "com.example.app13", "com.example.app15", "com.example.app17", "com.example.app25", "com.example.app27", "com.example.app34", "com.example.app35", "com.example.app36", "com.example.app37"]}
"""
    /// Every item an app listed, with the bar it is drawn on (nil: not on any bar, as a hidden icon is): bundle ID, name, index, bar, x, y, width, height.
    static let appItems: [(app: String, name: String?, index: Int, bar: String?, x: Double, y: Double, width: Double, height: Double)] = [
        ("com.example.app24", nil, 0, second, -1032, -217.5, 34, 24),
        ("com.example.app12", nil, 0, second, -735, -217.5, 24, 24),
        ("com.example.app07", nil, 0, nil, -1, 2147, 42, 26),
        ("com.apple.systemuiserver", nil, 0, second, -170, -217.5, 17, 24),
        ("com.apple.systemuiserver", nil, 1, second, -1137, -216.5, 22, 22),
        ("com.apple.systemuiserver", nil, 2, second, -1099, -216.5, 22, 22),
        ("com.example.app06", nil, 0, main, 3251, 2, 198, 24),
        ("com.apple.TextInputMenuAgent", nil, 0, second, -816, -217.5, 37, 24),
        ("com.example.app16", nil, 0, main, 3447, 2, 88, 24),
        ("com.example.app18", nil, 0, second, -954, -217.5, 24, 24),
        ("com.example.app30", nil, 0, second, -1167, -217.5, 15, 24),
        ("com.example.app05", nil, 0, nil, -1, 2148, 34, 24),
        ("com.example.app20", nil, 0, second, -880, -217.5, 34, 24),
        ("com.example.app28", nil, 0, main, 3541, 2, 24, 24),
        ("com.example.app33", nil, 0, main, 3137, 2, 46, 24),
        ("com.example.app22", nil, 0, main, 3099, 2, 40, 24),
        ("com.example.mantel.testitem", "mantel.fixture.one", 0, second, -1278, -217.5, 24, 24),
        ("com.example.mantel.testitem", "mantel.fixture.two", 1, second, -1240, -217.5, 26, 24),
        ("com.example.mantel.testitem", "mantel.fixture.extra.1", 2, second, -1328, -217.5, 28, 24),
        ("com.example.mantel.testitem", "mantel.fixture.extra.2", 3, second, -1330, -217.5, 30, 24),
        ("com.example.mantel.testitem", "mantel.fixture.extra.3", 4, second, -338, -217.5, 32, 24),
        ("com.example.mantel.testitem", "mantel.fixture.extra.4", 5, second, -1334, -217.5, 34, 24),
        ("com.example.mantel.testitem", "mantel.fixture.extra.5", 6, second, -1336, -217.5, 36, 24),
        ("com.example.mantel.testitem", "mantel.fixture.extra.6", 7, second, -1338, -217.5, 38, 24),
        ("com.example.mantel.testitem", "mantel.fixture.extra.7", 8, second, -1340, -217.5, 40, 24),
        ("com.example.mantel.testitem", "mantel.fixture.extra.8", 9, second, -1342, -217.5, 42, 24),
        ("com.example.mantel.testitem", "mantel.fixture.extra.9", 10, second, -1348, -217.5, 44, 24),
        ("com.example.mantel.testitem", "mantel.fixture.extra.10", 11, second, -1376, -217.5, 46, 24),
        ("com.example.mantel.testitem", "mantel.fixture.extra.11", 12, main, 2009, 2, 48, 24),
        ("com.example.mantel.testitem", "mantel.fixture.extra.12", 13, main, 1945, 2, 50, 24),
        ("com.example.mantel", "mantel.dot.hidden", 0, main, 3069, 2, 24, 24),
        ("com.example.mantel", "mantel.dot.always", 1, main, 3031, 2, 24, 24),
    ]
    /// The system modules drawn on the main bar: name, x, y, width, height.
    static let modules: [(name: String, x: Double, y: Double, width: Double, height: Double)] = [
        ("battery", 3580, 0, 26, 30),
        ("clock", 3702, 0, 118, 30),
        ("controlcenter", 3660, 0, 26, 30),
        ("sound", 3222, 0, 22, 30),
        ("wifi", 3622, 0, 22, 30),
        ("bluetooth", 3190, 0, 16, 30),
    ]
}

extension OwnersTable {
    static var table: LayoutTableSnapshot { LayoutTableSnapshot(distances: distances) }

    static func sections() throws -> SectionModel {
        try JSONDecoder().decode(SectionModel.self, from: Data(sectionsJSON.utf8))
    }

    private static func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// The bar as that read saw it: every item drawn on a bar has its slot's frame there, an icon that isn't on any bar (a hidden one) has
    /// none, and the system modules are the ones the main bar draws.
    static func inventory(without apps: Set<String> = []) -> Inventory {
        var items: [MenuBarItem] = []
        var slots: [String: [CGRect]] = [:]
        for entry in appItems where !apps.contains(entry.app) {
            let id = entry.name.map { ItemID(bundleID: entry.app, key: .identifier($0)) } ?? ItemID(bundleID: entry.app, key: .index(entry.index))
            let kind: OwnItemKind? = switch entry.name {
            case OwnItems.hiddenDotName?: .hiddenDot
            case OwnItems.alwaysDotName?: .alwaysDot
            default: nil
            }
            var frames: [String: CGRect] = [:]
            if let bar = entry.bar {
                let frame = rect(entry.x, entry.y, entry.width, entry.height)
                frames[bar] = frame
                slots[bar, default: []].append(frame)
            }
            items.append(MenuBarItem(id: id, ownerBundleID: entry.app, appName: nil, label: nil, frames: frames, overflowedOn: [],
                                     isMantel: entry.app == own, ownKind: kind))
        }
        for module in modules {
            let frame = rect(module.x, module.y, module.width, module.height)
            slots[main, default: []].append(frame)
            items.append(MenuBarItem(id: .system(module.name), ownerBundleID: ItemID.systemBundleID, appName: nil, label: nil,
                                     frames: [main: frame], overflowedOn: [], isMantel: false))
        }
        let bars = [MenuBarGeometry(displayUUID: main, rect: mainBar, notch: nil), MenuBarGeometry(displayUUID: second, rect: secondBar, notch: nil)]
        let barSlots = slots.mapValues { $0.sorted { $0.minX < $1.minX }.map { BarSlot(frame: $0, name: nil) } }
        // The apps with an item here are the running ones: the read says so, as the scanner's does.
        return Inventory(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), bars: bars, items: items, chevrons: [:], reach: [],
                         problems: [], barSlots: barSlots, runningApps: Set(items.map(\.ownerBundleID)))
    }

    static func inputs(_ sections: SectionModel, inventory: Inventory) -> LayoutInputs {
        var widths: [ItemID: CGFloat] = [:]
        for item in inventory.items {
            if let frame = item.frames.values.first { widths[item.id] = frame.width }
        }
        return LayoutInputs(sections: sections, placement: .betweenSections, alwaysDotShown: true, dotsShown: true, dividerShown: true,
                            widths: widths)
    }
}
