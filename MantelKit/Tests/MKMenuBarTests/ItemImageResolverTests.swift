import AppKit
import Foundation
import MKCore
import MKLayout
import Testing

@testable import MKMenuBar

struct ItemImageResolverTests {
    private let folder = URL(filePath: "/tmp/mantel-resolver-test", directoryHint: .isDirectory)
    private static let ownBundleID = "com.example.mantel"
    private let app = ItemID(bundleID: "com.example.weather", key: .identifier("temp"))

    private func variant(_ name: String, monochrome: Bool) -> ImageVariant {
        ImageVariant(fileName: name, capturedAt: Date(timeIntervalSince1970: 0), pixelHash: name, pointSize: CGSize(width: 18, height: 18),
                     isMonochrome: monochrome)
    }

    private func record(_ variants: [BarAppearance: ImageVariant]) -> ItemImageRecord {
        ItemImageRecord(item: app, variants: variants, changeCount: 0, appItemCount: 1)
    }

    @Test func exactAppearanceWins() {
        let record = record([.light: variant("l.png", monochrome: true), .dark: variant("d.png", monochrome: true)])
        #expect(ItemImageResolver.source(for: app, record: record, want: .dark, folder: folder, ownBundleID: Self.ownBundleID)
                == .captured(folder.appending(path: "d.png"), recolorFor: nil))
    }

    @Test func monochromeOtherAppearanceIsRecolored() {
        let record = record([.light: variant("l.png", monochrome: true)])
        #expect(ItemImageResolver.source(for: app, record: record, want: .dark, folder: folder, ownBundleID: Self.ownBundleID)
                == .captured(folder.appending(path: "l.png"), recolorFor: .dark))
    }

    @Test func colouredOtherAppearanceUsedAsIs() {
        let record = record([.light: variant("l.png", monochrome: false)])
        #expect(ItemImageResolver.source(for: app, record: record, want: .dark, folder: folder, ownBundleID: Self.ownBundleID)
                == .captured(folder.appending(path: "l.png"), recolorFor: nil))
    }

    @Test func appIconFallback() {
        #expect(ItemImageResolver.source(for: app, record: nil, want: .light, folder: folder, ownBundleID: Self.ownBundleID) == .appIcon(bundleID: "com.example.weather"))
    }

    @Test func ownItemsAreNeverAnAppIcon() {
        let own = ItemID(bundleID: OwnItems.owner, key: .identifier("mantel.spacer.1"))
        #expect(ItemImageResolver.source(for: own, record: nil, want: .light, folder: folder, ownBundleID: Self.ownBundleID) == .placeholder)
    }

    @Test func anOwnItemNamedByTheRealBundleIDIsNeverAnAppIcon() {
        // A read of the menu bar names Mantel's items by its real bundle ID, and says what they are in `ownKind`.
        let dot = ItemID(bundleID: Self.ownBundleID, key: .identifier("dot"))
        #expect(ItemImageResolver.source(for: dot, record: nil, want: .light, folder: folder, ownBundleID: Self.ownBundleID) == .placeholder)
        // Nor does a picture found for it come before that: Mantel draws it.
        let kept = record([.light: variant("l.png", monochrome: true)])
        #expect(ItemImageResolver.source(for: dot, record: kept, want: .light, folder: folder, ownBundleID: Self.ownBundleID) == .placeholder)
        #expect(ItemImageResolver.source(for: app, record: nil, want: .light, folder: folder, ownBundleID: Self.ownBundleID)
                == .appIcon(bundleID: "com.example.weather"), "another app's item still is")
    }

    @Test func systemSymbolFallback() {
        #expect(ItemImageResolver.source(for: .system("clock"), record: nil, want: .light, folder: folder, ownBundleID: Self.ownBundleID) == .systemSymbol("clock"))
        #expect(ItemImageResolver.source(for: .system("battery"), record: nil, want: .light, folder: folder, ownBundleID: Self.ownBundleID) == .systemSymbol("battery.100"))
    }

    @Test func placeholderLast() {
        #expect(ItemImageResolver.source(for: .system("somethingnew"), record: nil, want: .light, folder: folder, ownBundleID: Self.ownBundleID) == .placeholder)
    }

    @Test func fallbackSymbolNamesExist() {
        for name in ItemImageResolver.symbolNames.values.sorted() + [ItemImageResolver.placeholderSymbol] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) is a symbol")
        }
    }
}
