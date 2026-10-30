import MKCore
import MKLayout
import Testing

@testable import MKSearch

@Suite("Icon search entries and records", .timeLimit(.minutes(1)))
struct IconRecordSearchTests {
    @Test func oneEntryPerCurrentIconAndOnePerAppNotRunning() {
        let a = "com.example.a", b = "com.example.b"
        let aNow = ItemID(bundleID: a, key: .index(0)), aOld = ItemID(bundleID: a, key: .identifier("x.old")), aOlder = ItemID(bundleID: a, key: .index(1))
        let bFirst = ItemID(bundleID: b, key: .index(0)), bSecond = ItemID(bundleID: b, key: .index(1)), bThird = ItemID(bundleID: b, key: .identifier("y"))
        var sections = SectionModel()
        sections.noteIcons([aOld, aNow, aOlder, bFirst, bSecond, bThird])
        let stale = sections.staleRecords(current: [a: [aNow]])
        let inventory = Inventory(capturedAt: .now, bars: [], items: [], chevrons: [:], reach: [], problems: [])

        let entries = IconSearchEntries.build(inventory: inventory, sections: sections, preferences: IconPreferences(), names: [:],
                                              running: [a], stale: stale)
        #expect(entries.map(\.item) == [aNow, bFirst], "the running app's current icon, and the app that isn't running once")
        // Everyone running, nothing known to be stale: every record, as it was.
        let all = IconSearchEntries.build(inventory: inventory, sections: sections, preferences: IconPreferences(), names: [:])
        #expect(all.count == 6)
    }
}
