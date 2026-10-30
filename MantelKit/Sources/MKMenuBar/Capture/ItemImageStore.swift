import CoreGraphics
import CryptoKit
import Foundation
import MKCore

/// One picture of an item, for one bar appearance.
public struct ImageVariant: Codable, Sendable, Equatable {
    public let fileName: String
    public let capturedAt: Date
    public let pixelHash: String
    /// The trimmed image's size in points.
    public let pointSize: CGSize
    public let isMonochrome: Bool

    public init(fileName: String, capturedAt: Date, pixelHash: String, pointSize: CGSize, isMonochrome: Bool) {
        self.fileName = fileName
        self.capturedAt = capturedAt
        self.pixelHash = pixelHash
        self.pointSize = pointSize
        self.isMonochrome = isMonochrome
    }
}

/// Everything kept of one item's picture.
public struct ItemImageRecord: Codable, Sendable, Equatable {
    public let item: ItemID
    public var variants: [BarAppearance: ImageVariant]
    /// How many times the picture came out different from the one kept before it.
    public var changeCount: Int
    /// The app's item count when the picture was captured: what an index-keyed ID stands for.
    public var appItemCount: Int

    /// The picture keeps changing (a clock, a counter): it is recaptured whenever it is drawn.
    public var isDynamic: Bool { changeCount >= 2 }

    public init(item: ItemID, variants: [BarAppearance: ImageVariant] = [:], changeCount: Int = 0, appItemCount: Int) {
        self.item = item
        self.variants = variants
        self.changeCount = changeCount
        self.appItemCount = appItemCount
    }
}

/// The trimmed pictures of the menu bar's items, a PNG for each item and bar appearance, and an index of them.
public actor ItemImageStore {
    static let indexName = "index.json"

    private let folder: URL
    private let clock: any Clock
    private var byItem: [String: ItemImageRecord]
    private var listeners: [UUID: AsyncStream<Set<ItemID>>.Continuation] = [:]

    /// - Parameter folder: the folder the pictures and `index.json` are in. A missing or unreadable index starts empty.
    public init(folder: URL, clock: any Clock) {
        self.folder = folder
        self.clock = clock
        let data = try? Data(contentsOf: folder.appending(path: Self.indexName, directoryHint: .notDirectory))
        let decoder = Self.decoder
        if let data, let saved = try? decoder.decode([String: ItemImageRecord].self, from: data) {
            byItem = saved
        } else {
            byItem = [:]
        }
    }

    public func record(for item: ItemID) -> ItemImageRecord? {
        byItem[item.string]
    }

    /// Every record, in the order of the item IDs' text.
    public func records() -> [ItemImageRecord] {
        byItem.keys.sorted().compactMap { byItem[$0] }
    }

    public func fileURL(for variant: ImageVariant) -> URL {
        Self.fileURL(for: variant, in: folder)
    }

    /// Where a variant's PNG is in `folder`.
    public static func fileURL(for variant: ImageVariant, in folder: URL) -> URL {
        folder.appending(path: variant.fileName, directoryHint: .notDirectory)
    }

    /// Saves a matted icon, trimmed to its content bounds. Returns whether the picture changed: it is new, or its pixels are not the
    /// ones kept for that appearance.
    @discardableResult
    public func save(_ icon: MattedIcon, scale: CGFloat, for item: ItemID, appItemCount: Int) throws -> Bool {
        let appearance = icon.barAppearance
        let trimmed = IconMatting.trimmed(icon)
        var record = byItem[item.string] ?? ItemImageRecord(item: item, appItemCount: appItemCount)
        // Pictures taken when the app had another count of items may be of other items: they go.
        if !record.variants.isEmpty, record.appItemCount != appItemCount {
            for (other, variant) in record.variants where other != appearance {
                try? FileManager.default.removeItem(at: fileURL(for: variant))
                record.variants[other] = nil
            }
        }
        let existing = record.variants[appearance]
        let changed = existing?.pixelHash != icon.pixelHash

        let name = Self.fileName(for: item, appearance: appearance)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if changed {
            guard let png = IconMatting.pngData(trimmed) else { throw CocoaError(.fileWriteUnknown) }
            try AtomicFile.write(png, to: folder.appending(path: name, directoryHint: .notDirectory))
        }
        let safeScale = scale > 0 ? scale : 1
        record.variants[appearance] = ImageVariant(
            fileName: name, capturedAt: clock.now(), pixelHash: icon.pixelHash,
            pointSize: CGSize(width: CGFloat(trimmed.width) / safeScale, height: CGFloat(trimmed.height) / safeScale),
            isMonochrome: icon.isMonochrome)
        if existing != nil, changed { record.changeCount += 1 }
        record.appItemCount = appItemCount
        byItem[item.string] = record
        try writeIndex()
        if changed { announce([item]) }
        return changed
    }

    /// Drops the pictures whose identity may have moved: those of index-keyed items of an app that answered, whose item count is not
    /// the count the pictures were taken at, and those of the records that a check of an app's saved icons took out (`records`): they are
    /// of icons that aren't the app's now.
    ///
    /// **An app with exactly one icon, and no picture of it,** has the picture of one of the records that were taken out given to it
    /// instead: the first, by the text of its ID, of those **by index** (the app's own icon by its own list). A record named after a slot
    /// may have a picture of whatever drew that slot (another app's item), so its picture is dropped.
    public func reconcile(with inventory: Inventory, droppedRecords records: Set<ItemID> = []) throws {
        var dropped: Set<ItemID> = records.filter { byItem[$0.string] != nil }
        var given: Set<ItemID> = []  // the records a picture was taken from and given to
        for (bundleID, olds) in Dictionary(grouping: dropped.sorted { $0.string < $1.string }, by: \.bundleID) {
            let now = Set(inventory.items(ofApp: bundleID).map(\.id))
            guard now.count == 1, let target = now.first, byItem[target.string] == nil,
                  let old = olds.first(where: { if case .index = $0.key { true } else { false } }),
                  let record = givenPicture(of: old, to: target) else { continue }
            byItem[target.string] = record
            byItem[old.string] = nil
            dropped.remove(old)
            given.formUnion([old, target])
        }
        for record in byItem.values {
            guard case .index = record.item.key, !inventory.unansweredApps.contains(record.item.bundleID) else { continue }
            let count = inventory.items(ofApp: record.item.bundleID).count
            guard count > 0, count != record.appItemCount else { continue }
            dropped.insert(record.item)
        }
        guard !dropped.isEmpty || !given.isEmpty else { return }
        for item in dropped {
            for variant in byItem[item.string]?.variants.values.map({ $0 }) ?? [] {
                try? FileManager.default.removeItem(at: fileURL(for: variant))
            }
            byItem[item.string] = nil
        }
        try writeIndex()
        announce(dropped.union(given))
    }

    /// The record of `old` as the record of `target`: its pictures' files under the names `target` gives them. Nil when a file can't be
    /// moved (the old record is then dropped as any other).
    private func givenPicture(of old: ItemID, to target: ItemID) -> ItemImageRecord? {
        guard let record = byItem[old.string] else { return nil }
        var variants: [BarAppearance: ImageVariant] = [:]
        for (appearance, variant) in record.variants {
            let name = Self.fileName(for: target, appearance: appearance)
            let destination = folder.appending(path: name, directoryHint: .notDirectory)
            do {
                if name != variant.fileName {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: fileURL(for: variant), to: destination)
                }
            } catch {
                for moved in variants.values { try? FileManager.default.removeItem(at: fileURL(for: moved)) }
                return nil
            }
            variants[appearance] = ImageVariant(fileName: name, capturedAt: variant.capturedAt, pixelHash: variant.pixelHash,
                                                pointSize: variant.pointSize, isMonochrome: variant.isMonochrome)
        }
        return ItemImageRecord(item: target, variants: variants, changeCount: record.changeCount, appItemCount: 1)
    }

    /// The IDs each save or drop touched.
    public func changes() -> AsyncStream<Set<ItemID>> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Set<ItemID>>.makeStream()
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeListener(id) }
        }
        return stream
    }

    // MARK: Files

    /// `<first 16 hex of the SHA-256 of the ID's text>-<light|dark>.png`.
    static func fileName(for item: ItemID, appearance: BarAppearance) -> String {
        let digest = SHA256.hash(data: Data(item.string.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return "\(hex)-\(appearance.rawValue).png"
    }

    private func writeIndex() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(byItem)
        try AtomicFile.write(data, to: folder.appending(path: Self.indexName, directoryHint: .notDirectory))
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func announce(_ items: Set<ItemID>) {
        for listener in listeners.values { listener.yield(items) }
    }

    private func removeListener(_ id: UUID) {
        listeners[id] = nil
    }
}
