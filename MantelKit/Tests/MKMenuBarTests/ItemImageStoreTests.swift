import CoreGraphics
import Foundation
import ImageIO
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

struct ItemImageStoreTests {
    private let folder = TemporaryFolder(prefix: "mantel-images")
    private let clock = FakeClock()

    private func makeStore() -> ItemImageStore {
        ItemImageStore(folder: folder.url.appending(path: "ItemImages", directoryHint: .isDirectory), clock: clock)
    }

    private var images: URL { folder.url.appending(path: "ItemImages", directoryHint: .isDirectory) }
    private let weather = ItemID(bundleID: "com.example.weather", key: .identifier("temp"))
    private let notes = ItemID(bundleID: "com.example.notes", key: .index(0))

    @Test func saveWritesTrimmedPNGAndIndex() async throws {
        let store = makeStore()
        let icon = mattedDisc()
        let changed = try await store.save(icon, scale: 2, for: weather, appItemCount: 1)
        #expect(changed)

        let record = try #require(await store.record(for: weather))
        let variant = try #require(record.variants[icon.barAppearance])
        #expect(variant.fileName.range(of: #"^[0-9a-f]{16}-(light|dark)\.png$"#, options: .regularExpression) != nil)
        let url = await store.fileURL(for: variant)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let png = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(png.width == Int(icon.contentBounds.width))
        #expect(png.height == Int(icon.contentBounds.height))
        #expect(png.width < 72)
        #expect(FileManager.default.fileExists(atPath: images.appending(path: "index.json").path))
    }

    @Test func sameHashIsNotAChange() async throws {
        let store = makeStore()
        let icon = mattedDisc()
        #expect(try await store.save(icon, scale: 2, for: weather, appItemCount: 1))
        clock.advance(by: .seconds(60))
        #expect(try await store.save(icon, scale: 2, for: weather, appItemCount: 1) == false)
        let record = try #require(await store.record(for: weather))
        #expect(record.changeCount == 0)
        #expect(record.variants[icon.barAppearance]?.capturedAt == clock.now())
    }

    @Test func secondChangeMakesDynamic() async throws {
        let store = makeStore()
        try await store.save(mattedDisc(colour: imageColour(1, 0, 0)), scale: 2, for: weather, appItemCount: 1)
        #expect(try await store.save(mattedDisc(colour: imageColour(0, 1, 0)), scale: 2, for: weather, appItemCount: 1))
        #expect(await store.record(for: weather)?.isDynamic == false)
        #expect(try await store.save(mattedDisc(colour: imageColour(0, 0, 1)), scale: 2, for: weather, appItemCount: 1))
        let record = try #require(await store.record(for: weather))
        #expect(record.changeCount == 2)
        #expect(record.isDynamic)
    }

    @Test func itemCountChangeDropsIndexKeyedImages() async throws {
        let store = makeStore()
        let icon = mattedDisc()
        try await store.save(icon, scale: 2, for: notes, appItemCount: 2)
        let variant = try #require(await store.record(for: notes)?.variants[icon.barAppearance])
        let url = await store.fileURL(for: variant)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let items = (0..<3).map { CollectorWorld.item(ItemID(bundleID: "com.example.notes", key: .index($0)), bundleID: "com.example.notes", slot: $0) }
        try await store.reconcile(with: CollectorWorld.inventory(items))
        #expect(await store.record(for: notes) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func unansweredAppIsNotReconciled() async throws {
        let store = makeStore()
        try await store.save(mattedDisc(), scale: 2, for: notes, appItemCount: 2)
        let items = [CollectorWorld.item(ItemID(bundleID: "com.example.notes", key: .index(0)), bundleID: "com.example.notes", slot: 0)]
        try await store.reconcile(with: CollectorWorld.inventory(items, unanswered: ["com.example.notes"]))
        #expect(await store.record(for: notes) != nil)
    }

    @Test func aOneIconAppsPictureUnderARecordThatWasTakenOutIsGivenToItsIcon() async throws {
        let store = makeStore()
        let phantom = ItemID(bundleID: "com.example.notes", key: .index(1))
        let icon = notes
        let picture = mattedDisc()
        try await store.save(picture, scale: 2, for: phantom, appItemCount: 1)
        let old = try #require(await store.record(for: phantom)?.variants[picture.barAppearance])
        let oldURL = await store.fileURL(for: old)
        let items = [CollectorWorld.item(icon, bundleID: "com.example.notes", slot: 0)]

        try await store.reconcile(with: CollectorWorld.inventory(items), droppedRecords: [phantom])

        #expect(await store.record(for: phantom) == nil)
        let given = try #require(await store.record(for: icon))
        let variant = try #require(given.variants[picture.barAppearance])
        #expect(variant.pixelHash == old.pixelHash && variant.pointSize == old.pointSize)
        #expect(variant.fileName == ItemImageStore.fileName(for: icon, appearance: picture.barAppearance))
        #expect(given.appItemCount == 1)
        #expect(FileManager.default.fileExists(atPath: await store.fileURL(for: variant).path))
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(await ItemImageStore(folder: images, clock: clock).record(for: icon)?.variants == given.variants, "and it is in the index")
    }

    @Test func aPictureUnderARecordNamedAfterASlotIsNotGivenToTheAppsIcon() async throws {
        // A name the app's own list never gave was a slot's, and the picture under it may be of whatever drew that slot.
        let store = makeStore()
        let slotNamed = ItemID(bundleID: "com.example.notes", key: .identifier("x.phantom"))
        try await store.save(mattedDisc(), scale: 2, for: slotNamed, appItemCount: 1)
        try await store.reconcile(with: CollectorWorld.inventory([CollectorWorld.item(notes, bundleID: "com.example.notes", slot: 0)]),
                                  droppedRecords: [slotNamed])
        #expect(await store.record(for: slotNamed) == nil)
        #expect(await store.record(for: notes) == nil)
    }

    @Test func aPictureUnderARecordThatWasTakenOutIsDroppedWhenTheAppHasSeveralIconsOrTheIconHasOne() async throws {
        let store = makeStore()
        let phantom = ItemID(bundleID: "com.example.notes", key: .identifier("x.phantom"))
        try await store.save(mattedDisc(), scale: 2, for: phantom, appItemCount: 1)
        let two = [notes, ItemID(bundleID: "com.example.notes", key: .index(1))]
        try await store.reconcile(with: CollectorWorld.inventory(two.enumerated().map { CollectorWorld.item($1, bundleID: "com.example.notes", slot: $0) }),
                                  droppedRecords: [phantom])
        #expect(await store.record(for: phantom) == nil)
        #expect(await store.record(for: notes) == nil, "which icon it is isn't known")

        // The icon has a picture of its own: it keeps it, and the other goes.
        try await store.save(mattedDisc(level: 0.3), scale: 2, for: phantom, appItemCount: 1)
        try await store.save(mattedDisc(level: 0.8), scale: 2, for: notes, appItemCount: 1)
        let own = await store.record(for: notes)
        try await store.reconcile(with: CollectorWorld.inventory([CollectorWorld.item(notes, bundleID: "com.example.notes", slot: 0)]),
                                  droppedRecords: [phantom])
        #expect(await store.record(for: phantom) == nil)
        #expect(await store.record(for: notes) == own)
    }

    @Test func indexIsSortedAndAtomic() async throws {
        let store = makeStore()
        try await store.save(mattedDisc(), scale: 2, for: weather, appItemCount: 1)
        try await store.save(mattedDisc(), scale: 2, for: notes, appItemCount: 1)
        let text = try String(contentsOf: images.appending(path: "index.json"), encoding: .utf8)
        let notesAt = try #require(text.range(of: "\"com.example.notes#0\"")?.lowerBound)
        let weatherAt = try #require(text.range(of: "\"com.example.weather::temp\"")?.lowerBound)
        #expect(notesAt < weatherAt)
        let names = try FileManager.default.contentsOfDirectory(atPath: images.path)
        #expect(names.allSatisfy { !$0.hasSuffix(".tmp") })

        // A new store reads it back.
        let again = makeStore()
        #expect(await again.records().count == 2)
        let original = await store.record(for: weather)
        #expect(await again.record(for: weather) == original)
    }
}
