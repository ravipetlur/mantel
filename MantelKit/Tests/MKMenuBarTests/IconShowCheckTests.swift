import MKCore
import Testing

@testable import MKMenuBar

/// When an icon can't be shown, and what is said of it.
@Suite("Icon show check")
struct IconShowCheckTests {
    private let app = ItemID(bundleID: "com.example.notes", key: .identifier("main"))
    private let system = ItemID.system("nowplaying")

    @Test func aRunningAppCanBeShown() {
        #expect(IconShowCheck.refusal(for: app, hasProcess: true, hasItems: true, planConceals: true) == nil)
        #expect(IconShowCheck.refusal(for: app, hasProcess: true, hasItems: false, planConceals: false) == nil)
    }

    @Test func anAppThatQuitButIsStillListedIsLeftToTheDriver() {
        // Remembered with an item in the last read: the driver's own rule lets it through, so a show does too.
        #expect(IconShowCheck.refusal(for: app, hasProcess: false, hasItems: true, planConceals: false) == nil)
    }

    @Test func anAppWithNoProcessAndNoItemsIsNotRunning() {
        #expect(IconShowCheck.refusal(for: app, hasProcess: false, hasItems: false, planConceals: false) == .notRunning)
        #expect(IconShowCheck.refusal(for: app, hasProcess: false, hasItems: false, planConceals: true) == .notRunning)
    }

    @Test func aSystemItemThePlanTakesOffTheBarCantBeReached() {
        #expect(IconShowCheck.refusal(for: system, hasProcess: false, hasItems: false, planConceals: true) == .unreachable)
    }

    @Test func anAppThatIsNeverDrawnCantBeReached() {
        // macOS doesn't tie its icon to it, or the person turned it off in System Settings › Menu Bar: a reveal draws nothing.
        #expect(IconShowCheck.refusal(for: app, hasProcess: true, hasItems: true, planConceals: false, neverDrawn: true) == .unreachable)
        #expect(IconShowCheck.refusal(for: app, hasProcess: false, hasItems: true, planConceals: true, neverDrawn: true) == .unreachable)
    }

    @Test func anAppThatIsNeverDrawnAndNotRunningIsNotRunning() {
        #expect(IconShowCheck.refusal(for: app, hasProcess: false, hasItems: false, planConceals: false, neverDrawn: true) == .notRunning)
    }

    @Test func aSystemItemOnTheBarCanBeShownWithoutAProcessOrItems() {
        #expect(IconShowCheck.refusal(for: system, hasProcess: false, hasItems: false, planConceals: false) == nil)
    }

    @Test func anIconTheAppDoesNotListIsUnreachableAtOnce() {
        let app = ItemID(bundleID: "com.example.app", key: .identifier("x.old"))
        #expect(IconShowCheck.refusal(for: app, hasProcess: true, hasItems: true, planConceals: false, noSuchIcon: true) == .unreachable)
        // An app that isn't running is still not running.
        #expect(IconShowCheck.refusal(for: app, hasProcess: false, hasItems: false, planConceals: false, noSuchIcon: true) == .notRunning)
        #expect(IconShowCheck.refusal(for: app, hasProcess: true, hasItems: true, planConceals: false, noSuchIcon: false) == nil)
    }
}
