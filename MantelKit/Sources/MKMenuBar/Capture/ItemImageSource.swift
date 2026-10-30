import Foundation
import MKCore
import MKLayout

/// Where the picture of an item comes from, best first.
public enum ItemImageSource: Sendable, Equatable {
    /// A captured picture; `recolorFor` says to recolour a monochrome one captured on the other appearance.
    case captured(URL, recolorFor: BarAppearance?)
    case appIcon(bundleID: String)
    /// A symbol, per system module.
    case systemSymbol(String)
    case placeholder
}

public enum ItemImageResolver {
    /// The symbol that stands for each system module when it has no captured picture.
    public static let symbolNames: [String: String] = [
        "clock": "clock",
        "wifi": "wifi",
        "battery": "battery.100",
        "sound": "speaker.wave.2",
        "bluetooth": "wave.3.right",
        "controlcenter": "switch.2",
        "airdrop": "dot.radiowaves.left.and.right",
        "audiovideo": "video",
        "display": "display",
        "focusmodes": "moon",
        "now-playing": "play.circle",
        "screencapture": "camera.viewfinder",
        "spotlight": "magnifyingglass",
        "siri": "mic",
        "userswitcher": "person.crop.circle",
        "keyboardbrightness": "light.max",
        "vpn": "network.badge.shield.half.filled",
    ]

    public static let placeholderSymbol = "app.dashed"

    /// `ownBundleID`: Mantel's own bundle ID. Its items are drawn by Mantel and are never an app's icon, whether they are named by it (as
    /// a read of the menu bar names them) or by `OwnItems.owner` (as the layout does).
    public static func source(for item: ItemID, record: ItemImageRecord?, want: BarAppearance, folder: URL,
                              ownBundleID: String) -> ItemImageSource {
        func url(_ variant: ImageVariant) -> URL { ItemImageStore.fileURL(for: variant, in: folder) }
        if item.bundleID == ownBundleID || OwnItems.isOwn(item) { return .placeholder }
        if let record {
            if let exact = record.variants[want] { return .captured(url(exact), recolorFor: nil) }
            let other: BarAppearance = want == .light ? .dark : .light
            if let opposite = record.variants[other], opposite.isMonochrome { return .captured(url(opposite), recolorFor: want) }
            if let any = record.variants[other] ?? record.variants.values.first { return .captured(url(any), recolorFor: nil) }
        }
        if case .system(let module) = item.key {
            if let symbol = symbolNames[module] { return .systemSymbol(symbol) }
            return .placeholder
        }
        return .appIcon(bundleID: item.bundleID)
    }
}
