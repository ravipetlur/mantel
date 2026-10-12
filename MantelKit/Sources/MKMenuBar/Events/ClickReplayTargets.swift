import CoreGraphics
import MKCore

/// Where the clicks that macOS ignores while icons are hidden are held and replayed (`SystemClickTap`).
///
/// For as long as an allowlist is live, macOS ignores a click on the clock, however the clock is listed on it. The click is held,
/// the allowlist is lifted, and the click is made again a moment later. Only the clock needs this: the other system items (Wi-Fi,
/// battery, sound, Bluetooth, Control Center) open as usual under an allowlist, so a hold for them would only lift it for nothing.
public enum ClickReplayTargets {
    /// The system items whose clicks are held, by module (`ItemID.systemModule`).
    public static let modules: Set<String> = ["clock"]

    /// Where each of those items is on each display, in CoreGraphics global points, as the inventory last read them: the item's frame
    /// on every display that has one, in the order of the displays' UUIDs, each place once.
    ///
    /// An item with no frame (macOS isn't drawing it) adds nothing, and so does a display that is no longer in the inventory: every new
    /// inventory replaces what was held for the one before it.
    public static func rects(in inventory: Inventory) -> [CGRect] {
        var rects: [CGRect] = []
        for item in inventory.items {
            guard case .system(let module) = item.id.key, modules.contains(module) else { continue }
            for (_, frame) in item.frames.sorted(by: { $0.key < $1.key }) where !frame.isEmpty && !rects.contains(frame) {
                rects.append(frame)
            }
        }
        return rects
    }

    /// Whether the tap is wanted while `engine` is the one in charge of hiding: only for the allowlist, the one whose assertion makes
    /// macOS ignore the clock. Any other engine leaves the clock working, and nothing is held.
    public static func isWanted(whileHidingWith engine: HidingEngineKind?) -> Bool {
        engine == .allowlist
    }
}

/// Whether the tap that holds clicks on the clock may be running: while the allowlist hides icons (`ClickReplayTargets.isWanted`), and
/// never again once it has been shut down.
///
/// The shut-down is final, and is for quitting. The session goes on publishing states while the app is putting things back, and each
/// one tells whoever owns the tap what the engine is: a state that says "the allowlist" would start a tap again, and a click on the
/// clock in that window would lift the allowlist and put it back, an assertion macOS holds for about 5 seconds after Mantel has gone.
public struct ClockClickGate: Sendable, Equatable {
    public private(set) var isShutDown = false

    public init() {}

    /// From now on nothing is wanted, whatever engine is in charge.
    public mutating func shutDown() {
        isShutDown = true
    }

    /// Whether the tap is wanted while `engine` is the one in charge of hiding (nil: none is known).
    public func isWanted(whileHidingWith engine: HidingEngineKind?) -> Bool {
        !isShutDown && ClickReplayTargets.isWanted(whileHidingWith: engine)
    }
}
