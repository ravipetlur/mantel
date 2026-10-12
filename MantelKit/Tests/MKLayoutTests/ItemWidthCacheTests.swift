import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

@Suite("Item width cache", .timeLimit(.minutes(1)))
struct ItemWidthCacheTests {
    private let app = "com.example.a"
    private func frame(width: CGFloat) -> CGRect { CGRect(x: 500, y: 0, width: width, height: 30) }

    @Test func anItemNeverSeenOnTheBarTakesTheWidthItsAppSaid() {
        // A width that is unknown can't be said to fit, so an app that was moved for room would never be tried again. What its app
        // reported for it (a frame that no slot claimed) is better than that, until a slot gives the real one.
        let item = Fixtures.itemID(app, "one")
        let reported = MenuBarItem(id: item, ownerBundleID: app, appName: nil, label: nil, frames: [:], overflowedOn: [], isMantel: false,
                                   reportedWidth: 24)
        var cache = ItemWidthCache()
        cache.update(from: Fixtures.inventory([reported]))
        #expect(cache.width(of: item) == 24)
        #expect(cache.width(ofApp: app, in: Fixtures.inventory([reported])) == 24)

        cache.update(from: Fixtures.inventory([Fixtures.item(item, frame: frame(width: 38))]))
        #expect(cache.width(of: item) == 38, "the slot's width wins from then on")
        cache.update(from: Fixtures.inventory([reported]))
        #expect(cache.width(of: item) == 38, "and a report doesn't put it back")
    }

    @Test func theWidthOfASlotIsKnownOnlyOnceTheItemHadOne() {
        let item = Fixtures.itemID(app, "one")
        let reported = MenuBarItem(id: item, ownerBundleID: app, appName: nil, label: nil, frames: [:], overflowedOn: [], isMantel: false,
                                   reportedWidth: 24)
        var cache = ItemWidthCache()
        cache.update(from: Fixtures.inventory([reported]))
        #expect(cache.slotWidth(of: item) == nil, "an app's own report is the icon's, and a slot is wider")
        cache.update(from: Fixtures.inventory([Fixtures.item(item, frame: frame(width: 38))]))
        #expect(cache.slotWidth(of: item) == 38)
    }

    @Test func keepsLastVisibleWidth() {
        let item = Fixtures.itemID(app, "one")
        var cache = ItemWidthCache()
        #expect(cache.width(of: item) == nil)

        cache.update(from: Fixtures.inventory([Fixtures.item(item, frame: frame(width: 30))]))
        #expect(cache.width(of: item) == 30)

        // Concealed: the item has no frame, and keeps the width it had.
        cache.update(from: Fixtures.inventory([Fixtures.item(item)]))
        #expect(cache.width(of: item) == 30)

        // Not in the inventory at all (its app didn't answer, or has quit): the width stays.
        cache.update(from: Fixtures.inventory([], unansweredApps: [app]))
        #expect(cache.width(of: item) == 30)

        // A frame with no width says nothing.
        cache.update(from: Fixtures.inventory([Fixtures.item(item, frame: frame(width: 0))]))
        #expect(cache.width(of: item) == 30)

        // Visible again, and different: the new width.
        cache.update(from: Fixtures.inventory([Fixtures.item(item, frame: frame(width: 24))]))
        #expect(cache.width(of: item) == 24)

        // On two displays: the wider of the frames.
        let both = MenuBarItem(id: item, ownerBundleID: app, appName: nil, label: nil,
                               frames: ["one": frame(width: 22), "two": frame(width: 26)], overflowedOn: [], isMantel: false)
        cache.update(from: Fixtures.inventory([both]))
        #expect(cache.width(of: item) == 26)
    }

    @Test func appWidthIsSumOrNil() {
        let one = Fixtures.itemID(app, "one")
        let two = Fixtures.itemID(app, "two")
        var cache = ItemWidthCache()
        cache.update(from: Fixtures.inventory([Fixtures.item(one, frame: frame(width: 30)), Fixtures.item(two, frame: frame(width: 22))]))

        // Both known, whether the app is on the bar or concealed now.
        let onBar = Fixtures.inventory([Fixtures.item(one, frame: frame(width: 30)), Fixtures.item(two, frame: frame(width: 22))])
        #expect(cache.width(ofApp: app, in: onBar) == 52)
        let concealed = Fixtures.inventory([Fixtures.item(one), Fixtures.item(two)])
        #expect(cache.width(ofApp: app, in: concealed) == 52)

        // One of them never seen: the total isn't known.
        let three = Fixtures.itemID(app, "three")
        let grown = Fixtures.inventory([Fixtures.item(one), Fixtures.item(two), Fixtures.item(three)])
        #expect(cache.width(ofApp: app, in: grown) == nil)

        // An app with no item in the inventory has no width either, and another app's items aren't added in.
        #expect(cache.width(ofApp: app, in: .empty) == nil)
        #expect(cache.width(ofApp: "com.example.other", in: onBar) == nil)
    }
}
