import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

@Suite("Room estimate", .timeLimit(.minutes(1)))
struct RoomEstimateTests {
    private let bar = MenuBarGeometry(displayUUID: "main", rect: CGRect(x: 0, y: 0, width: 1728, height: 32), notch: nil)
    private let notch = CGRect(x: 771.5, y: 0, width: 185, height: 32)

    private func item(x: CGFloat, width: CGFloat = 30, y: CGFloat = 1) -> CGRect {
        CGRect(x: x, y: y, width: width, height: 30)
    }

    @Test func menusToLeftmostItem() {
        // Menus end at 400; the left-most item starts at 900, whatever order the frames come in.
        let frames = [item(x: 1500), item(x: 900), item(x: 1200)]
        #expect(RoomEstimate.freeWidth(bar: bar, appMenusMaxX: 400, visibleItemFrames: frames) == 500)

        // Items on another display (a bar of its own, further right) aren't this bar's.
        let other = [item(x: 2000, y: 1), item(x: 1800, y: 1)]
        #expect(RoomEstimate.freeWidth(bar: bar, appMenusMaxX: 400, visibleItemFrames: frames + other) == 500)
        // Nor are those below it on the same display.
        #expect(RoomEstimate.freeWidth(bar: bar, appMenusMaxX: 400, visibleItemFrames: frames + [item(x: 600, y: 400)]) == 500)
    }

    @Test func notchBlocksTheLeftSide() {
        let notched = MenuBarGeometry(displayUUID: "main", rect: bar.rect, notch: notch)
        let frames = [item(x: 1200), item(x: 1400)]
        // The menus end left of the notch, so the room starts where the notch does.
        #expect(RoomEstimate.freeWidth(bar: notched, appMenusMaxX: 400, visibleItemFrames: frames) == 1200 - 956.5)
        #expect(RoomEstimate.freeWidth(bar: notched, appMenusMaxX: nil, visibleItemFrames: frames) == 1200 - 956.5)
        // Menus that run on to the right of the notch are what matters then.
        #expect(RoomEstimate.freeWidth(bar: notched, appMenusMaxX: 1000, visibleItemFrames: frames) == 200)
        // Without a notch, the same menus leave all of the room they would.
        #expect(RoomEstimate.freeWidth(bar: bar, appMenusMaxX: 400, visibleItemFrames: frames) == 800)
    }

    @Test func noItemsUsesBarRight() {
        #expect(RoomEstimate.freeWidth(bar: bar, appMenusMaxX: 400, visibleItemFrames: []) == 1328)
        let notched = MenuBarGeometry(displayUUID: "main", rect: bar.rect, notch: notch)
        #expect(RoomEstimate.freeWidth(bar: notched, appMenusMaxX: nil, visibleItemFrames: []) == 1728 - 956.5)
        // Neither the menus nor a notch to go by: from the bar's left edge.
        #expect(RoomEstimate.freeWidth(bar: bar, appMenusMaxX: nil, visibleItemFrames: []) == 1728)
        #expect(RoomEstimate.freeWidth(bar: bar, appMenusMaxX: nil, visibleItemFrames: [item(x: 600)]) == 600)
    }

    @Test func neverNegative() {
        // The menus run into the first item.
        #expect(RoomEstimate.freeWidth(bar: bar, appMenusMaxX: 1000, visibleItemFrames: [item(x: 900)]) == 0)
        // And past the end of the bar.
        #expect(RoomEstimate.freeWidth(bar: bar, appMenusMaxX: 2000, visibleItemFrames: []) == 0)
        let notched = MenuBarGeometry(displayUUID: "main", rect: bar.rect, notch: notch)
        #expect(RoomEstimate.freeWidth(bar: notched, appMenusMaxX: nil, visibleItemFrames: [item(x: 800)]) == 0)
    }

    @Test func untiedSlotsCountAsOccupied() {
        // Two icons macOS draws that Mantel couldn't name sit between the menus and the first icon it can: they take room,
        // and the caller puts them in with the visible items.
        let named = [item(x: 1200), item(x: 1400)]
        let slots = [item(x: 800, width: 28), item(x: 840, width: 28)]
        let inventory = Fixtures.inventory([], untiedSlots: ["main": slots])

        #expect(RoomEstimate.freeWidth(bar: bar, appMenusMaxX: 400, visibleItemFrames: named) == 800)
        let occupied = named + (inventory.untiedSlots["main"] ?? [])
        #expect(RoomEstimate.freeWidth(bar: bar, appMenusMaxX: 400, visibleItemFrames: occupied) == 400)
    }
}
