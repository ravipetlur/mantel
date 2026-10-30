import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Synchronization

@testable import MKMenuBar

/// A window list for a test: the windows it is given, and a count of how often it was read.
final class FakeWindowList: WindowListReading {
    private let windows: Mutex<[WindowInfo]>
    private let reads = Mutex(0)

    init(_ windows: [WindowInfo] = []) {
        self.windows = Mutex(windows)
    }

    func set(_ windows: [WindowInfo]) { self.windows.withLock { $0 = windows } }
    var readCount: Int { reads.withLock { $0 } }

    func onScreenWindows() -> [WindowInfo] {
        reads.withLock { $0 += 1 }
        return windows.withLock { $0 }
    }
}

/// A menu bar made of fake Accessibility trees, with made-up apps (`com.example.*`) and Apple's own module identifiers.
///
/// What it holds, left to right on a bar:
/// - **Third-party items:** two of the weather app's, with identifiers of their own; the notes app's, with none; the VPN app's, whose
///   name is one AppKit made up (`_NS:93`); two of the sync app's, with none, listed by the app right-to-left (so the order the app
///   lists them in isn't the order they are in); Mantel's two dots; and, unless asked not to, the test item's two.
/// - **System items:** airdrop, audiovideo, sound, wifi, battery, controlcenter and clock.
///
/// Every display has the same items. MenuBarAgent has several windows for each display (one per Space), each listing them in an order of
/// its own, and a few of them lack the identifiers of the third-party slots. The apps list their items on one bar only (the first, unless
/// asked otherwise), about six points inside the slot, where they are; the slots on the other bars are the same items, told by the
/// slot's own name where it has one and by their order where it hasn't.
enum InventoryFixtures {
    static let agentPID: pid_t = 50
    static let ownBundleID = "com.example.mantel"
    static let testItemBundleID = "com.example.mantel.testitem"
    static let weather = "com.example.weather"
    static let notes = "com.example.notes"
    static let vpn = "com.example.vpn"
    static let sync = "com.example.sync"

    struct Options {
        /// The first process ID the apps are given: another Mac has other ones.
        var pidBase: pid_t = 1000
        /// How many windows MenuBarAgent has for each display (one per Space).
        var windowsPerDisplay = 5
        /// Decides the order each window lists its slots in.
        var seed: UInt64 = 1
        /// Apps whose items are concealed: their slots have no frame and their own frames are the stale ones macOS reports.
        var concealed: Set<String> = []
        var includeTestItem = true
        /// The third-party slots carry no name at all, in any window.
        var stripThirdPartyNames = false
        /// The world of macOS 27: no third-party app names its items, in its own list or on its slots. Only Mantel's items and the test item's
        /// have names (the dots', the test item's extras).
        var unnamedApps = false
        /// The windows (by their place among a display's) that lack the names of the third-party slots. By default every third one, from
        /// the third.
        var windowsWithoutNames: Set<Int>?
        /// The bar (by its place among the displays) the apps list their items on.
        var listingDisplay = 0
        /// How many of the third-party items a full bar still shows, right of the «, the rest being piled at it.
        var visibleOnPileBar = 0
        /// Whether the apps' own lists give their items the identifiers they have (the slots' names are another matter).
        var appsReportIdentifiers = true
        /// The system modules whose slots have a frame that is far below the bar: where macOS parks an icon it isn't drawing.
        var parkedSystemModules: Set<String> = []
        /// Mantel's two dots are the left-most icons, as they are on a real bar (Hidden and Always Hidden apps are concealed and take no
        /// room, and the dots sit left of every Shown app).
        var ownItemsFirst = false
        /// An icon that doesn't fit has no slot and the bar has no «, as on macOS 27: the icon says where it would be, left of the notch,
        /// where none of the slots is.
        var undrawnOverflow = false
        /// An app that is concealed reports the place it had on the bar, where its slot was, and not the parked place far from every bar.
        var concealedKeepTheirPlace = false
        /// Apps whose icons say they are at a place left of the notch whatever is done to them: the frames of an app often don't change when
        /// it is hidden or shown (`undrawnOverflow`'s place, where no slot is).
        var staleApps: Set<String> = []
        /// Where, from the display's left edge, the stale apps' places start (each icon of an app 38 points right of the one before).
        var stalePlaceX: CGFloat = 484
        /// Apps whose items report their frames this many points to the right of where they are (an app whose frames are from before the
        /// bar moved, or whose icon has traded places with its neighbour's: the slots stay where they are).
        var frameShifts: [String: CGFloat] = [:]
        /// The items left to right on the bar, by the name each has (its title when it has none): the ones named come first, in this order,
        /// and the others follow as they were. (An app lists its items in its own order whatever they are drawn in.)
        var itemOrder: [String]?
        /// Items of Mantel's own the app lists besides the dots, by the name each is told by (`mantel.spacer.<id>`, `mantel.group.<id>`, the
        /// divider's), drawn after the dots. An item the app has hidden with `isVisible` isn't listed, so they come and go in a test.
        var ownExtras: [String] = []
        /// Mantel's items among the dots that aren't listed (••, while nothing is in Always Hidden), by name.
        var ownOmitted: Set<String> = []

        init(pidBase: pid_t = 1000, windowsPerDisplay: Int = 5, seed: UInt64 = 1, concealed: Set<String> = [], includeTestItem: Bool = true,
             stripThirdPartyNames: Bool = false, windowsWithoutNames: Set<Int>? = nil, listingDisplay: Int = 0, visibleOnPileBar: Int = 0,
             appsReportIdentifiers: Bool = true, parkedSystemModules: Set<String> = [], ownItemsFirst: Bool = false,
             undrawnOverflow: Bool = false, concealedKeepTheirPlace: Bool = false,
             staleApps: Set<String> = [], stalePlaceX: CGFloat = 484, frameShifts: [String: CGFloat] = [:], itemOrder: [String]? = nil,
             ownExtras: [String] = [], ownOmitted: Set<String> = [], unnamedApps: Bool = false) {
            self.unnamedApps = unnamedApps
            self.itemOrder = itemOrder
            self.ownExtras = ownExtras
            self.ownOmitted = ownOmitted
            self.pidBase = pidBase
            self.windowsPerDisplay = windowsPerDisplay
            self.seed = seed
            self.concealed = concealed
            self.includeTestItem = includeTestItem
            self.stripThirdPartyNames = stripThirdPartyNames
            self.windowsWithoutNames = windowsWithoutNames
            self.listingDisplay = listingDisplay
            self.visibleOnPileBar = visibleOnPileBar
            self.appsReportIdentifiers = appsReportIdentifiers
            self.parkedSystemModules = parkedSystemModules
            self.ownItemsFirst = ownItemsFirst
            self.undrawnOverflow = undrawnOverflow
            self.concealedKeepTheirPlace = concealedKeepTheirPlace
            self.staleApps = staleApps
            self.stalePlaceX = stalePlaceX
            self.frameShifts = frameShifts
        }
    }

    struct Fixture: Sendable {
        let ax: FakeAX
        let layout: DisplayLayout
        /// MenuBarAgent and the apps.
        let running: [RunningApp]
        /// The Accessibility nodes of MenuBarAgent's windows, for each display in the order of the layout.
        let windows: [[Int]]
        /// The bar of each display, CoreGraphics points.
        let bars: [CGRect]
        /// For each window of MenuBarAgent's, the third-party slots that have a name of their own (Accessibility nodes), and the
        /// names, whether the window shows them or not.
        let namedSlots: [Int: [(slot: Int, name: String)]]

        func pid(of bundleID: String) -> pid_t? { running.first { $0.bundleID == bundleID }?.pid }

        /// The window gains the names of its third-party slots, as a window can after a time.
        func giveNames(toWindow window: Int) {
            for (slot, name) in namedSlots[window] ?? [] { ax.setAttribute(AXName.identifier, .string(name), on: slot) }
        }

        /// The window loses the names of its third-party slots (a window that was made again).
        func takeNames(fromWindow window: Int) {
            for (slot, _) in namedSlots[window] ?? [] { ax.setAttribute(AXName.identifier, .string(""), on: slot) }
        }

        /// How many times the slots of this window of MenuBarAgent have been read.
        func slotReads(ofWindow window: Int) -> Int {
            ((try? ax.children(of: ax.ref(window))) ?? []).map { ax.attributeReads(on: ax.id(of: $0)) }.reduce(0, +)
        }

        /// The Accessibility nodes of an app's own items, in the order it lists them.
        func extrasNodes(of bundleID: String) -> [Int] {
            guard let pid = pid(of: bundleID), case .elements(let bars)? = try? ax.attribute(AXName.extrasMenuBar, of: ax.application(pid: pid)),
                  let bar = bars.first, let children = try? ax.children(of: bar) else { return [] }
            return children.map(ax.id(of:))
        }
    }

    // MARK: The fixtures

    /// The desk, lid closed: the main display and the portrait one, both with roomy bars (30 points).
    static func desk(_ options: Options = Options()) -> Fixture {
        make(layout: .desk, piled: [], options)
    }

    /// The laptop alone: its bar (33 points) is full, and eight slots are piled at x 958 to 967, left of the « at x 979.
    static func laptop(_ options: Options = Options(includeTestItem: false)) -> Fixture {
        make(layout: .laptop, piled: [DisplayFixtures.laptopAlone.uuid], options)
    }

    /// The desk with the laptop's lid open beside it: the laptop's bar is the full one.
    static func deskWithLaptopOpen(_ options: Options = Options()) -> Fixture {
        make(layout: .deskWithLaptopOpen, piled: [DisplayFixtures.laptopRightOfDesk.uuid], options)
    }

    // MARK: The items

    private struct Third {
        let bundleID: String
        /// What the app's own list of items says of the item (its identifier), and what the slot says.
        let name: String?
        let slotName: String?
        let title: String
        /// The item's place in its app's list.
        let position: Int
    }

    /// Left to right on a bar.
    private static let thirdParty: [Third] = [
        Third(bundleID: weather, name: "weather.temp", slotName: "weather.temp", title: "Weather", position: 0),
        Third(bundleID: weather, name: "weather.alerts", slotName: "weather.alerts", title: "Alerts", position: 1),
        Third(bundleID: notes, name: nil, slotName: nil, title: "Notes", position: 0),
        Third(bundleID: vpn, name: "_NS:93", slotName: "_NS:93", title: "VPN", position: 0),
        Third(bundleID: sync, name: nil, slotName: nil, title: "Sync B", position: 1),
        Third(bundleID: sync, name: nil, slotName: nil, title: "Sync A", position: 0),
        Third(bundleID: ownBundleID, name: "mantel.dot.hidden", slotName: "mantel.dot.hidden", title: "Mantel", position: 0),
        Third(bundleID: ownBundleID, name: "mantel.dot.always", slotName: "mantel.dot.always", title: "Mantel", position: 1),
        Third(bundleID: testItemBundleID, name: "mantel.fixture.one", slotName: "mantel.fixture.one", title: "one", position: 0),
        Third(bundleID: testItemBundleID, name: "mantel.fixture.two", slotName: "mantel.fixture.two", title: "two", position: 1),
    ]

    private static let appNames: [(bundleID: String, name: String)] = [
        (ownBundleID, "Mantel"), (weather, "Weather"), (notes, "Notes"), (vpn, "VPN"), (sync, "Sync"), (testItemBundleID, "MantelTestItem"),
    ]

    /// Right to left from the bar's right edge.
    private static let system: [(module: String, description: String, width: CGFloat)] = [
        ("clock", "Clock", 80), ("controlcenter", "Control Center", 36), ("battery", "Battery", 50), ("wifi", "Wi-Fi", 36),
        ("sound", "Sound", 36), ("audiovideo", "Recording", 28), ("airdrop", "AirDrop", 28),
    ]

    private struct SlotSpec {
        let identifier: String?
        let isThirdParty: Bool
        let role: String
        let subrole: String?
        let description: String?
        let frame: CGRect?
    }

    // MARK: Building

    private static func make(layout: DisplayLayout, piled: Set<String>, _ options: Options) -> Fixture {
        let ax = FakeAX()
        var items = thirdParty.filter { (options.includeTestItem || $0.bundleID != testItemBundleID) && !options.ownOmitted.contains($0.name ?? "") }
        for (index, name) in options.ownExtras.enumerated() {
            items.append(Third(bundleID: ownBundleID, name: name, slotName: name, title: "Mantel", position: 2 + index))
        }
        if options.ownItemsFirst { items = items.filter { $0.bundleID == ownBundleID } + items.filter { $0.bundleID != ownBundleID } }
        if let order = options.itemOrder {
            let named = order.compactMap { name in items.first { ($0.name ?? $0.title) == name } }
            items = named + items.filter { entry in !named.contains { $0.bundleID == entry.bundleID && $0.position == entry.position } }
        }
        if options.unnamedApps {
            let named: Set<String> = [ownBundleID, testItemBundleID]
            items = items.map { named.contains($0.bundleID) ? $0 : Third(bundleID: $0.bundleID, name: nil, slotName: nil, title: $0.title, position: $0.position) }
        }
        var bars: [CGRect] = []
        var windowsByDisplay: [[Int]] = []
        var namedSlots: [Int: [(slot: Int, name: String)]] = [:]
        var home: [Int: CGRect] = [:]  // the slot of each item (by its place in `items`) on the bar the apps list them on

        for (displayIndex, display) in layout.displays.enumerated() {
            let area = layout.cgRect(fromAppKit: display.frame)
            let bar = CGRect(x: area.minX, y: area.minY, width: area.width, height: display.isBuiltIn ? 33 : 30)
            bars.append(bar)
            let isPiled = piled.contains(display.uuid)
            let placed = slotSpecs(bar: bar, items: items, piled: isPiled, visible: options.visibleOnPileBar, concealed: options.concealed,
                                   parked: options.parkedSystemModules, undrawn: options.undrawnOverflow)
            if displayIndex == options.listingDisplay {
                for (index, frame) in placed.third.enumerated() { home[index] = frame }
            }

            var ids: [Int] = []
            for windowIndex in 0..<options.windowsPerDisplay {
                let window = ax.addAgentWindow(agent: agentPID, frame: bar)
                ids.append(window)
                var generator = SplitMix(seed: options.seed &+ UInt64(displayIndex * 100 + windowIndex))
                // Some windows lack the identifiers the third-party slots usually carry.
                let lacking = options.windowsWithoutNames ?? Set(stride(from: 2, to: max(options.windowsPerDisplay, 3), by: 3))
                let hasNames = !options.stripThirdPartyNames && !lacking.contains(windowIndex)
                for slot in placed.all.shuffled(using: &generator) {
                    let node = ax.addSlot(in: window, identifier: slot.isThirdParty && !hasNames ? nil : slot.identifier, role: slot.role,
                                          subrole: slot.subrole, description: slot.description, frame: slot.frame)
                    if slot.isThirdParty, let name = slot.identifier { namedSlots[window, default: []].append((node, name)) }
                }
            }
            windowsByDisplay.append(ids)
        }

        // The apps list their items on the first bar, six points in from the slot, or put them aside where macOS reports stale ones.
        var running: [RunningApp] = [.fake(agentPID, MenuBarReader.menuBarAgentBundleID, "MenuBarAgent")]
        for (offset, app) in appNames.enumerated() where options.includeTestItem || app.bundleID != testItemBundleID {
            let pid = options.pidBase + pid_t(offset)
            running.append(.fake(pid, app.bundleID, app.name))
            let own = items.enumerated().filter { $0.element.bundleID == app.bundleID }.sorted { $0.element.position < $1.element.position }
            var extras: [FakeAX.Extra] = []
            for (index, entry) in own {
                let isConcealed = options.concealed.contains(app.bundleID)
                let frame: CGRect?
                if options.staleApps.contains(app.bundleID) {
                    // Its place left of the notch, which no slot has, whether it is concealed or drawn.
                    let strip = layout.displays.first.map { layout.cgRect(fromAppKit: $0.frame).minX } ?? 0
                    frame = CGRect(x: strip + options.stalePlaceX + 38 * CGFloat(entry.position), y: 2, width: 24, height: 28)
                } else if isConcealed, options.concealedKeepTheirPlace {
                    // Its last place, which no slot has any more.
                    frame = home[index].map { $0.insetBy(dx: 6, dy: 1) }
                } else if isConcealed {
                    // Where macOS reports an icon it isn't drawing: at the left edge, a dozen points above the bottom of the main display.
                    let bottom = layout.main.map { layout.cgRect(fromAppKit: $0.frame).maxY } ?? 1000
                    frame = CGRect(x: entry.position == 0 ? 7 : -1, y: bottom - 12, width: 24, height: 24)
                } else {
                    frame = home[index].map { $0.insetBy(dx: 6, dy: 1).offsetBy(dx: options.frameShifts[app.bundleID] ?? 0, dy: 0) }
                }
                extras.append(FakeAX.Extra(title: entry.title, identifier: options.appsReportIdentifiers ? entry.name : nil, frame: frame))
            }
            ax.addApp(pid: pid, extras: extras)
        }
        return Fixture(ax: ax, layout: layout, running: running, windows: windowsByDisplay, bars: bars, namedSlots: namedSlots)
    }

    private static func slotSpecs(bar: CGRect, items: [Third], piled: Bool, visible: Int, concealed: Set<String>, parked: Set<String>,
                                  undrawn: Bool) -> (all: [SlotSpec], third: [CGRect]) {
        var all: [SlotSpec] = []
        let top = bar.minY + (piled ? 1 : 0)
        let height: CGFloat = piled ? 30 : bar.height

        var cursor = bar.maxX - 12
        for entry in system {
            let x = cursor - entry.width
            all.append(SlotSpec(identifier: "com.apple.menuextra.\(entry.module)", isThirdParty: false, role: "AXGroup", subrole: "AXHostingView",
                                description: entry.description,
                                frame: CGRect(x: x, y: parked.contains(entry.module) ? top + 1848 : top, width: entry.width, height: height)))
            cursor = x - 6
        }

        var thirdFrames: [CGRect] = Array(repeating: .zero, count: items.count)
        // On a full bar the first items are piled up at the «, each at a place of its own a little to the right of the one before;
        // the others are as on a bar with room.
        let piledCount = piled ? max(items.count - visible, 0) : 0
        for index in 0..<piledCount {
            if undrawn {
                // No slot and no «: the icon says where it would be, a place of its own left of the notch.
                thirdFrames[index] = CGRect(x: bar.minX + 484 + 38 * CGFloat(index), y: bar.minY + 1, width: 36, height: 30)
            } else {
                thirdFrames[index] = CGRect(x: bar.minX + 958 + 1.25 * CGFloat(index), y: top, width: 24, height: height)
            }
        }
        if piled, !undrawn {
            all.append(SlotSpec(identifier: nil, isThirdParty: false, role: "AXButton", subrole: nil, description: "Show hidden menu bar items",
                                frame: CGRect(x: bar.minX + 979, y: bar.minY + 1, width: 17.5, height: 30)))
        }
        cursor -= 14
        for index in items.indices.reversed() where index >= piledCount {
            let x = cursor - 36
            thirdFrames[index] = CGRect(x: x, y: top, width: 36, height: height)
            cursor = x - 8
        }
        for (index, item) in items.enumerated() {
            // An icon that isn't drawn has no slot.
            if undrawn, index < piledCount { continue }
            let isConcealed = concealed.contains(item.bundleID)
            all.append(SlotSpec(identifier: item.slotName, isThirdParty: true, role: "AXGroup", subrole: "AXHostingView", description: nil,
                                frame: isConcealed ? nil : thirdFrames[index]))
        }
        return (all, thirdFrames)
    }
}

/// A random number generator with a seed, so that the order a window lists its slots in is the same on every run.
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
