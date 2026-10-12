/// What Mantel knows of macOS's own menu bar items.
///
/// A module is the last part of the item's identifier (`wifi` for `com.apple.menuextra.wifi`; see `ItemID.systemModule`). The
/// number is the one macOS's allowlist of items to keep on the bar names the module by, measured on a real Mac. A module with
/// no number here (AirDrop is one) can't be hidden by number: Mantel lists it as one that can't be hidden yet.
public enum SystemItemTable {
    /// The allowlist number of each module Mantel can hide.
    public static let numbers: [String: Int] = [
        "battery": 0,
        "bluetooth": 1,
        "clock": 2,
        "sound": 5,
        "wifi": 6,
        "controlcenter": 8,
    ]

    /// The modules that stay on the bar unless the person allows hiding them: hiding either one takes away the way to reach
    /// Notification Center or Control Center.
    public static let unmovable: Set<String> = ["clock", "controlcenter"]

    private static let titles: [String: String] = [
        "battery": "Battery",
        "bluetooth": "Bluetooth",
        "clock": "Clock",
        "sound": "Sound",
        "wifi": "Wi-Fi",
        "controlcenter": "Control Center",
    ]

    /// The allowlist number of a module, or nil for one Mantel doesn't know.
    public static func number(of module: String) -> Int? {
        numbers[module]
    }

    /// The name Settings gives a module, or nil for one Mantel doesn't know.
    public static func title(of module: String) -> String? {
        titles[module]
    }
}
