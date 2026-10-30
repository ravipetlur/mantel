import MKCore
import Testing

@testable import MKMenuBar

/// When an icon can't be shown, and what is said of it.
@Suite("Icon show check", .timeLimit(.minutes(2)))
struct IconShowCheckTests {
    struct Case: Sendable {
        var item: ItemID
        var hasProcess: Bool
        var hasItems: Bool
        var planConceals: Bool
        var neverDrawn = false
        var noSuchIcon = false
        var refusal: IconClickFailure?
    }

    private static let notes = ItemID(bundleID: "com.example.notes", key: .identifier("main"))
    private static let nowPlaying = ItemID.system("nowplaying")
    private static let oldIcon = ItemID(bundleID: "com.example.app", key: .identifier("x.old"))

    @Test(arguments: [
        // A running app can be shown.
        Case(item: notes, hasProcess: true, hasItems: true, planConceals: true, refusal: nil),
        Case(item: notes, hasProcess: true, hasItems: false, planConceals: false, refusal: nil),
        // One that quit but was remembered with an item in the last read: the driver's own rule lets it through, so a show does too.
        Case(item: notes, hasProcess: false, hasItems: true, planConceals: false, refusal: nil),
        // No process and no items is not running, never drawn or not.
        Case(item: notes, hasProcess: false, hasItems: false, planConceals: false, refusal: .notRunning),
        Case(item: notes, hasProcess: false, hasItems: false, planConceals: true, refusal: .notRunning),
        Case(item: notes, hasProcess: false, hasItems: false, planConceals: false, neverDrawn: true, refusal: .notRunning),
        // A system item the plan takes off the bar can't be reached; one on the bar can be shown without a process or items.
        Case(item: nowPlaying, hasProcess: false, hasItems: false, planConceals: true, refusal: .unreachable),
        Case(item: nowPlaying, hasProcess: false, hasItems: false, planConceals: false, refusal: nil),
        // An app that is never drawn (macOS doesn't tie its icon to it, or it is turned off in System Settings › Menu Bar): a reveal draws nothing.
        Case(item: notes, hasProcess: true, hasItems: true, planConceals: false, neverDrawn: true, refusal: .unreachable),
        Case(item: notes, hasProcess: false, hasItems: true, planConceals: true, neverDrawn: true, refusal: .unreachable),
        // An icon the app does not list is unreachable at once; an app that isn't running is still not running.
        Case(item: oldIcon, hasProcess: true, hasItems: true, planConceals: false, noSuchIcon: true, refusal: .unreachable),
        Case(item: oldIcon, hasProcess: false, hasItems: false, planConceals: false, noSuchIcon: true, refusal: .notRunning),
        Case(item: oldIcon, hasProcess: true, hasItems: true, planConceals: false, noSuchIcon: false, refusal: nil),
    ])
    func whenAnIconCantBeShown(_ check: Case) {
        #expect(IconShowCheck.refusal(for: check.item, hasProcess: check.hasProcess, hasItems: check.hasItems, planConceals: check.planConceals,
                                      neverDrawn: check.neverDrawn, noSuchIcon: check.noSuchIcon) == check.refusal)
    }
}
