import CoreGraphics
import Foundation
import MKCore
import MKLayout
import Testing

@Suite("Layout table", .timeLimit(.minutes(1)))
struct LayoutTableTests {
    @Test func parseStatusAndModule() {
        #expect(LayoutKey.parse("status:com.example.weather::weather.temp") == .status(bundleID: "com.example.weather", name: "weather.temp"))
        #expect(LayoutKey.parse("module:Battery") == .module("Battery"))
        #expect(LayoutKey.parse("module:com.apple.menuextra.clock") == .module("com.apple.menuextra.clock"))
    }

    @Test func notAKeyIsNil() {
        for text in ["", "status:", "status:com.example.app", "status:com.example.app::", "status:::name", "module:", "other:thing",
                     "com.example.app::name", "Status:com.example.app::name"] {
            #expect(LayoutKey.parse(text) == nil, "\(text)")
        }
    }

    @Test func statusKeyRoundTrip() {
        let key = LayoutKey.status(bundleID: "com.example.sync", autosaveName: "Item-0")
        #expect(key == "status:com.example.sync::Item-0")
        #expect(LayoutKey.parse(key) == .status(bundleID: "com.example.sync", name: "Item-0"))
    }

    @Test func identifierWithColonsParses() {
        // The first `::` ends the bundle ID; the name keeps whatever colons it has.
        let name = "NSStatusItem Item::1:a::b"
        let key = LayoutKey.status(bundleID: "com.example.app", autosaveName: name)
        #expect(LayoutKey.parse(key) == .status(bundleID: "com.example.app", name: name))
        #expect(LayoutKey.parse("status:com.example.app::::") == .status(bundleID: "com.example.app", name: "::"))
    }

    @Test func keysOfAppIgnoreOtherApps() {
        let table = LayoutTableSnapshot(distances: [
            "status:com.example.app::b": 120, "status:com.example.app::a": 80, "status:com.example.app2::a": 40,
            "status:com.example.ap::a": 10, "module:Clock": 0, "module:Battery": 30, "garbage": 1,
        ])
        #expect(table.statusKeys(ofApp: "com.example.app") == ["status:com.example.app::a", "status:com.example.app::b"],
                "a bundle ID that starts with the same letters is another app")
        #expect(table.statusKeys(ofApp: "com.example.none").isEmpty)
        #expect(table.moduleKeys == ["module:Battery", "module:Clock"])
    }

    @Test func aTableReadsBackFromJSON() throws {
        let table = LayoutTableSnapshot(distances: ["status:com.example.app::a": 80.5, "module:Clock": 0])
        let back = try JSONDecoder().decode(LayoutTableSnapshot.self, from: JSONEncoder().encode(table))
        #expect(back == table)
    }

    @Test func moduleKeyNamesAreTheMeasuredOnes() {
        let names = LayoutKey.moduleKeyNames
        #expect(names["clock"] == "Clock")
        #expect(names["controlcenter"] == "BentoBox-0")
        #expect(names["wifi"] == "WiFi")
        #expect(names["battery"] == "Battery")
        #expect(names["sound"] == "Sound")
        #expect(names["bluetooth"] == "Bluetooth")
        // The modules that come and go, as the inventory names them (the part after `com.apple.menuextra.`).
        #expect(names["now-playing"] == "NowPlaying")
        #expect(names["audiovideo"] == "AudioVideoModule")
        #expect(names["airdrop"] == "AirDrop")
        #expect(names["nowplaying"] == nil)
    }

    private func system(_ module: String, drawn: Bool) -> MenuBarItem {
        let frame = CGRect(x: 0, y: 0, width: 30, height: 24)
        return MenuBarItem(id: .system(module), ownerBundleID: ItemID.systemBundleID, appName: nil, label: nil,
                           frames: drawn ? ["d": frame] : [:], overflowedOn: [], isMantel: false)
    }

    private func inventory(_ items: [MenuBarItem]) -> Inventory {
        Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: [], items: items, chevrons: [:], reach: [], problems: [])
    }

    private let table = LayoutTableSnapshot(distances: [
        "module:Clock": 0, "module:WiFi": 155, "module:NowPlaying": 662.5, "module:AudioVideoModule": 829, "module:FocusModes": 300,
        "module:AirDrop": 895,
    ])

    @Test func presentModulesAreTheDrawnOnes() {
        let present = LayoutKey.presentModules(in: inventory([system("wifi", drawn: true), system("airdrop", drawn: false),
                                                              system("unheardof", drawn: true)]), table: table)
        #expect(present == ["wifi": "WiFi"])
    }

    @Test func aModuleTheMapDoesntNameIsMatchedByNameIgnoringCaseAndPunctuation() {
        let present = LayoutKey.presentModules(in: inventory([system("focus-mode", drawn: true), system("Wi_Fi", drawn: true)]),
                                               table: table)
        // `focusmode` is the start of `FocusModes`; `wifi` is `WiFi` exactly.
        #expect(present == ["focus-mode": "FocusModes", "Wi_Fi": "WiFi"])
    }

    @Test func nowPlayingDrawnSetsTheStartOfTheApps() {
        // The inventory names Now Playing `now-playing` and AirDrop `airdrop`; both are drawn, so the furthest of them sets the start.
        let items = [system("clock", drawn: true), system("wifi", drawn: true), system("now-playing", drawn: true),
                     system("airdrop", drawn: true)]
        let present = LayoutKey.presentModules(in: inventory(items), table: table)
        #expect(present["now-playing"] == "NowPlaying")
        let widths: [ItemID: CGFloat] = [.system("now-playing"): 16.5, .system("airdrop"): 28, .system("wifi"): 30]
        #expect(LayoutMath.systemStart(table: table, presentModules: present, widths: widths) == 895 + 28)
        // With AirDrop concealed it is Now Playing: 662.5 + 16.5.
        let without = LayoutKey.presentModules(in: inventory([system("wifi", drawn: true), system("now-playing", drawn: true),
                                                              system("airdrop", drawn: false)]), table: table)
        #expect(LayoutMath.systemStart(table: table, presentModules: without, widths: widths) == 679)
    }

    @Test func aWriteIsPlannedOnlyFromAReadThatHasBarsAndTheSystemItems() {
        func read(bars: Bool = true, system: Bool = true, concealedSystem: Bool = false, problems: [InventoryProblem] = []) -> Inventory {
            let frame = CGRect(x: 0, y: 0, width: 30, height: 24)
            let items = system ? [MenuBarItem(id: .system("clock"), ownerBundleID: ItemID.systemBundleID, appName: nil, label: nil,
                                              frames: concealedSystem ? [:] : ["d": frame], overflowedOn: [], isMantel: false)] : []
            return Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: bars ? [MenuBarGeometry(displayUUID: "d", rect: frame, notch: nil)] : [],
                             items: items, chevrons: [:], reach: [], problems: problems)
        }
        #expect(LayoutKey.canPlanFrom(read()))
        #expect(LayoutKey.canPlanFrom(read(problems: [.ambiguousSpace])), "a doubt about which copy of the bar is current is not no bar")
        #expect(!LayoutKey.canPlanFrom(read(bars: false)))
        #expect(!LayoutKey.canPlanFrom(read(system: false)), "no system item, no floor")
        #expect(!LayoutKey.canPlanFrom(read(concealedSystem: true)))
        for problem in [InventoryProblem.accessibilityNotGranted, .agentNotRunning, .agentHasNoWindows] {
            #expect(!LayoutKey.canPlanFrom(read(problems: [problem])))
        }
        #expect(!LayoutKey.canPlanFrom(.empty))
    }
}
