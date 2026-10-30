import Foundation
import MKCore
import Synchronization

/// The names macOS's order table gives an item.
///
/// The table (`TrailingItemPreferredPositions` in the menu bar's preferences) is keyed by text: `status:<bundle ID>::<autosave name>`
/// for an app's item and `module:<name>` for one of the system's. A bundle ID never holds a colon, so the first `::` after the prefix
/// ends it, and the autosave name that follows may hold any number of them.
public enum LayoutKey {
    /// What a key names.
    public enum Parsed: Sendable, Equatable {
        case status(bundleID: String, name: String)
        case module(String)
    }

    static let statusPrefix = "status:"
    static let modulePrefix = "module:"
    private static let separator = "::"

    /// The key of an app's item: `status:<bundle ID>::<autosave name>`.
    public static func status(bundleID: String, autosaveName: String) -> String {
        statusPrefix + bundleID + separator + autosaveName
    }

    /// What the key names; nil for a key that is neither form, or that has an empty part.
    public static func parse(_ key: String) -> Parsed? {
        if key.hasPrefix(statusPrefix) {
            let rest = key.dropFirst(statusPrefix.count)
            guard let split = rest.range(of: separator) else { return nil }
            let bundleID = String(rest[..<split.lowerBound])
            let name = String(rest[split.upperBound...])
            guard !bundleID.isEmpty, !name.isEmpty else { return nil }
            return .status(bundleID: bundleID, name: name)
        }
        if key.hasPrefix(modulePrefix) {
            let name = String(key.dropFirst(modulePrefix.count))
            return name.isEmpty ? nil : .module(name)
        }
        return nil
    }

    /// The name the order table gives each system module: the inventory's module name (`ItemID.systemModule`) to the part after `module:`.
    /// Control Center is `BentoBox-0`. The last six are in the table on a Mac that doesn't always draw them (Now Playing, Audio/Video and
    /// AirDrop come and go with what is playing, shared or nearby), with distances far to the left of most apps, so `LayoutMath.systemStart`
    /// counts a module while it is drawn. A module that isn't named here is matched to a key by `presentModules`.
    public static let moduleKeyNames: [String: String] = [
        "clock": "Clock", "controlcenter": "BentoBox-0", "wifi": "WiFi", "battery": "Battery", "sound": "Sound", "bluetooth": "Bluetooth",
        "display": "Display", "focusmodes": "FocusModes", "screenmirroring": "ScreenMirroring", "now-playing": "NowPlaying",
        "audiovideo": "AudioVideoModule", "airdrop": "AirDrop",
    ]

    /// The modules of `moduleKeyNames` that come and go (by their name in the inventory), all six the doc above says a Mac doesn't always
    /// draw: Display, Focus, Screen Mirroring, Now Playing, Audio/Video (the camera and microphone indicator) and AirDrop. The ones that
    /// stay are the rest. A write places the apps left of the ones that come and go, as macOS keeps them; an app among the ones that stay is
    /// never moved.
    public static let comingAndGoingModules: Set<String> = [
        "display", "focusmodes", "screenmirroring", "now-playing", "audiovideo", "airdrop",
    ]

    /// Whether a write can be planned from this read: it has a bar, says of no problem that the bar couldn't be seen (MenuBarAgent isn't
    /// running or has no windows, Device control and data access isn't granted), and draws a system module, the items that give the floor
    /// (`LayoutMath.systemStart`). A read that couldn't be taken says nothing of the bar: it has no item, so every app in it would count as
    /// not running, and the floor would be 0, among the system modules. Nothing is written from such a read.
    public static func canPlanFrom(_ inventory: Inventory) -> Bool {
        guard !inventory.bars.isEmpty else { return false }
        let unseen: Set<InventoryProblem> = [.accessibilityNotGranted, .agentNotRunning, .agentHasNoWindows]
        guard inventory.problems.allSatisfy({ !unseen.contains($0) }) else { return false }
        return inventory.items.contains { item in
            if case .system = item.id.key { return !item.isConcealed }
            return false
        }
    }

    /// The modules the inventory draws (a system item with a place on a bar), each with its name in the table. A module that isn't in
    /// `moduleKeyNames` is matched to the `module:` key of `table` whose name, ignoring case and anything that isn't a letter, is the
    /// module's or starts with it (`focusmode` finds `FocusModes`); that is logged once per module. A module with no such key is left out.
    public static func presentModules(in inventory: Inventory, table: LayoutTableSnapshot) -> [String: String] {
        var present: [String: String] = [:]
        for item in inventory.items where !item.isConcealed {
            guard case .system(let module) = item.id.key, present[module] == nil else { continue }
            if let name = moduleKeyNames[module] {
                present[module] = name
            } else if let name = similarKeyName(module, in: table) {
                present[module] = name
                warnOnce(module, "a system module isn't one this version knows; it was matched to \(name) in the order table by its name")
            } else {
                warnOnce(module, "a system module isn't one this version knows and has no key in the order table, so it isn't counted")
            }
        }
        return present
    }

    private static func similarKeyName(_ module: String, in table: LayoutTableSnapshot) -> String? {
        let wanted = letters(module)
        guard !wanted.isEmpty else { return nil }
        let names = table.moduleKeys.compactMap { key -> String? in
            if case .module(let name)? = parse(key) { return name }
            return nil
        }
        return names.first { letters($0) == wanted } ?? names.first { letters($0).hasPrefix(wanted) }
    }

    private static func letters(_ name: String) -> String {
        String(name.lowercased().filter(\.isLetter))
    }

    private static let warned = Mutex(Set<String>())

    private static func warnOnce(_ module: String, _ message: String) {
        guard warned.withLock({ $0.insert(module).inserted }) else { return }
        Log.warning("layout", "\(message): \(module)")
    }
}

/// What macOS's order table held when it was read: for every item it has a place for, how far the item is from the trailing edge of the
/// menu bar (the clock is nearest it; the larger the distance, the further left).
public struct LayoutTableSnapshot: Sendable, Equatable, Codable {
    /// The table's keys (`LayoutKey`) and their distances.
    public let distances: [String: Double]

    public init(distances: [String: Double]) {
        self.distances = distances
    }

    /// The keys of this app's items, in order of the key.
    public func statusKeys(ofApp bundleID: String) -> [String] {
        distances.keys.filter { key in
            if case .status(let owner, _)? = LayoutKey.parse(key) { return owner == bundleID }
            return false
        }.sorted()
    }

    /// The keys of the system's modules, in order of the key.
    public var moduleKeys: [String] {
        distances.keys.filter { key in
            if case .module? = LayoutKey.parse(key) { return true }
            return false
        }.sorted()
    }
}
