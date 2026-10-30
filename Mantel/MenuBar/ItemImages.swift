import AppKit
import ImageIO
import MKCore
import MKLayout
import MKMenuBar
import Observation

/// The best picture of every menu bar item, for whatever draws one: the second bar, the layout editor, the command bar.
///
/// It keeps a copy, on the main actor, of what the store holds (`ItemImageStore`), brought up to date from the store's `changes()`, and
/// decodes a picture when it is first asked for. What is asked for is answered at once, with what there is: the picture Mantel captured
/// of the icon for that bar appearance, or one captured on the other appearance (recoloured when it is of one colour), or the app's icon,
/// or the symbol that stands for a system item, or a placeholder (`ItemImageResolver`). A picture that comes in later replaces what was
/// given, and a view that asked is drawn again.
@MainActor
@Observable
final class ItemImages {
    private struct Key: Hashable {
        let item: ItemID
        let appearance: BarAppearance
    }

    /// The side of an app's icon or a symbol, in points: the height of a menu bar icon.
    private static let iconSide: CGFloat = 18

    private let store: ItemImageStore
    private let folder: URL
    private let ownBundleID: String
    /// What the store keeps of each item's pictures. It is read by `image(for:appearance:)`, so that a view that asked is drawn again when
    /// a picture changes.
    private var records: [ItemID: ItemImageRecord] = [:]
    /// The pictures that were decoded. Kept out of what is observed: filling it is what asking for a picture does, while a view is drawn.
    @ObservationIgnored private var decoded: [Key: NSImage] = [:]
    @ObservationIgnored private var watching: Task<Void, Never>?

    /// - Parameters:
    ///   - store: where the pictures of the icons are kept.
    ///   - folder: the folder the store's pictures are in.
    ///   - ownBundleID: Mantel's own bundle ID: its items are drawn by Mantel, and are never given the app's icon.
    init(store: ItemImageStore, folder: URL, ownBundleID: String) {
        self.store = store
        self.folder = folder
        self.ownBundleID = ownBundleID
    }

    /// Starts following the store. Once.
    func start() {
        guard watching == nil else { return }
        watching = Task { [weak self, store] in
            // The changes are asked for before what is there, so that none falls between the two.
            let changes = await store.changes()
            let all = await store.records()
            self?.replaceAll(all)
            for await touched in changes {
                var updated: [ItemID: ItemImageRecord?] = [:]
                for item in touched { updated[item] = await store.record(for: item) }
                self?.apply(updated)
            }
        }
    }

    /// Stops following the store.
    func stop() {
        watching?.cancel()
        watching = nil
    }

    /// The best picture there is of the item for a bar of this appearance.
    func image(for item: ItemID, appearance: BarAppearance) -> NSImage {
        let record = records[item]
        let key = Key(item: item, appearance: appearance)
        if let image = decoded[key] { return image }
        let image = makeImage(for: item, record: record, appearance: appearance)
        decoded[key] = image
        return image
    }

    /// When each captured picture was taken, for each icon that has some: what Diagnostics counts (`LayoutDiagnostics.imageSummary`).
    var capturedDates: [[Date]] {
        records.values.map { $0.variants.values.map(\.capturedAt) }
    }

    /// The path of the picture Mantel captured of the item, a PNG; nil when it has none (the app's icon or a symbol stands in then).
    func path(for item: ItemID, appearance: BarAppearance) -> String? {
        let source = ItemImageResolver.source(for: item, record: records[item], want: appearance, folder: folder, ownBundleID: ownBundleID)
        if case .captured(let url, _) = source { return url.path }
        return nil
    }

    // MARK: Following the store

    private func replaceAll(_ all: [ItemImageRecord]) {
        records = Dictionary(all.map { ($0.item, $0) }, uniquingKeysWith: { _, new in new })
        decoded = [:]
    }

    private func apply(_ updated: [ItemID: ItemImageRecord?]) {
        for (item, record) in updated {
            records[item] = record
            for appearance in BarAppearance.allCases { decoded[Key(item: item, appearance: appearance)] = nil }
        }
    }

    // MARK: Making a picture

    private func makeImage(for item: ItemID, record: ItemImageRecord?, appearance: BarAppearance) -> NSImage {
        switch ItemImageResolver.source(for: item, record: record, want: appearance, folder: folder, ownBundleID: ownBundleID) {
        case .captured(let url, let recolorFor):
            if let image = captured(url, recolorFor: recolorFor, record: record) { return image }
            // The file is gone or can't be read: what there is without it.
            return makeImage(for: item, record: nil, appearance: appearance)
        case .appIcon(let bundleID):
            return appIcon(bundleID)
        case .systemSymbol(let name):
            return symbol(name)
        case .placeholder:
            return symbol(ItemImageResolver.placeholderSymbol)
        }
    }

    private func captured(_ url: URL, recolorFor: BarAppearance?, record: ItemImageRecord?) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        if let appearance = recolorFor {
            image = IconMatting.recolored(image, isMonochrome: true, for: appearance) ?? image
        }
        let size = record?.variants.values.first { $0.fileName == url.lastPathComponent }?.pointSize
            ?? CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        return NSImage(cgImage: image, size: size)
    }

    private func appIcon(_ bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return symbol(ItemImageResolver.placeholderSymbol)
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: Self.iconSide, height: Self.iconSide)
        return icon
    }

    private func symbol(_ name: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: Self.iconSide, height: Self.iconSide))
        return image
    }
}
