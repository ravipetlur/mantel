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

    /// The picture for a bar of the appearance asked: the exact one, a monochrome other one recoloured, a coloured one as it is.
    @Test(arguments: [
        (["l.png": true, "d.png": true], BarAppearance.dark, "d.png", false),
        (["l.png": true], .dark, "l.png", true),
        (["l.png": false], .dark, "l.png", false),
    ] as [([String: Bool], BarAppearance, String, Bool)])
    func theAppearanceOfThePictureForTheBar(variants: [String: Bool], want: BarAppearance, file: String, recolored: Bool) {
        let record = record(Dictionary(uniqueKeysWithValues: variants.map { name, monochrome in
            (name.hasPrefix("l") ? BarAppearance.light : .dark, variant(name, monochrome: monochrome))
        }))
        #expect(ItemImageResolver.source(for: app, record: record, want: want, folder: folder, ownBundleID: Self.ownBundleID)
                == .captured(folder.appending(path: file), recolorFor: recolored ? want : nil))
    }

    @Test func appIconFallback() {
        #expect(ItemImageResolver.source(for: app, record: nil, want: .light, folder: folder, ownBundleID: Self.ownBundleID) == .appIcon(bundleID: "com.example.weather"))
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

}
