import CoreGraphics
import Foundation
import MKCore

/// Values the tests of the layout logic share. Every bundle ID is a synthetic `com.example.*` one.
enum Fixtures {
    static let display = "display-main"

    static func itemID(_ bundleID: String, _ name: String = "main") -> ItemID {
        ItemID(bundleID: bundleID, key: .identifier(name))
    }

    /// An item of the app that owns it, on `display`: with a frame, or concealed without one, and optionally in the overflow.
    static func item(_ id: ItemID, frame: CGRect? = nil, overflowed: Bool = false, isMantel: Bool = false) -> MenuBarItem {
        MenuBarItem(id: id, ownerBundleID: id.bundleID, appName: nil, label: nil,
                    frames: frame.map { [display: $0] } ?? [:], overflowedOn: overflowed ? [display] : [], isMantel: isMantel)
    }

    static func inventory(_ items: [MenuBarItem], unansweredApps: Set<String> = [], untiedSlots: [String: [CGRect]] = [:],
                          bars: [MenuBarGeometry] = []) -> Inventory {
        Inventory(capturedAt: date(0), bars: bars, items: items, chevrons: [:], reach: [], problems: [],
                  unansweredApps: unansweredApps, untiedSlots: untiedSlots)
    }

    /// A moment `seconds` after an arbitrary start.
    static func date(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }
}
