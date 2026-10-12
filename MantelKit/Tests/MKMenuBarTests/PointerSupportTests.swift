import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKLayout
import Synchronization
import Testing

@testable import MKMenuBar

/// How many times a list of windows was asked for, and what it holds.
private final class WindowReads: Sendable {
    private let state = Mutex((count: 0, windows: [WindowInfo]()))

    var count: Int { state.withLock { $0.count } }
    func set(_ windows: [WindowInfo]) { state.withLock { $0.windows = windows } }

    func read() -> [WindowInfo] {
        state.withLock { state in
            state.count += 1
            return state.windows
        }
    }
}

/// What the pointer's whereabouts need of the system: which bars are shown, without reading the window list more than it has to.
@Suite("Shown bars cache", .timeLimit(.minutes(1)))
struct ShownBarsCacheTests {
    private let main = "display-main"
    private let other = "display-other"
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private var bars: [MenuBarGeometry] {
        [MenuBarGeometry(displayUUID: main, rect: CGRect(x: 0, y: 0, width: 3360, height: 30), notch: nil),
         MenuBarGeometry(displayUUID: other, rect: CGRect(x: 3360, y: 773, width: 1728, height: 33), notch: nil)]
    }

    private func window(_ bar: MenuBarGeometry) -> WindowInfo {
        WindowInfo(number: 1, ownerPID: 60, ownerBundleID: nil, layer: WindowLevels.mainMenu, bounds: bar.rect, alpha: 1)
    }

    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    @Test func theConstantsAreFortyPointsAndAQuarterOfASecond() {
        #expect(ShownBarsCache.nearTopDistance == 40)
        #expect(ShownBarsCache.maximumAge == 0.25)
    }

    @Test func nothingIsReadWhileThePointerIsFarFromEveryTop() {
        var cache = ShownBarsCache()
        let reads = WindowReads()
        reads.set([window(bars[0])])
        for point in [CGPoint(x: 1500, y: 400), CGPoint(x: 1500, y: 71), CGPoint(x: -50, y: 10), CGPoint(x: 5000, y: 100)] {
            #expect(cache.shownBars(at: point, bars: bars, now: start, windows: reads.read).isEmpty, "\(point)")
        }
        #expect(reads.count == 0)
    }

    @Test func theListIsReadWhenThePointerIsNearTheTopOfABar() {
        var cache = ShownBarsCache()
        let reads = WindowReads()
        reads.set([window(bars[0])])
        // On the bar, at the very top of the screen, and 40 points below it.
        #expect(cache.shownBars(at: CGPoint(x: 1500, y: 0), bars: bars, now: start, windows: reads.read) == [main])
        #expect(reads.count == 1)
        #expect(ShownBarsCache.isNearATop(CGPoint(x: 1500, y: 40), bars: bars))
        #expect(!ShownBarsCache.isNearATop(CGPoint(x: 1500, y: 41), bars: bars))
        // Near the top of the second display's bar, which is lower.
        #expect(ShownBarsCache.isNearATop(CGPoint(x: 4000, y: 790), bars: bars))
        #expect(ShownBarsCache.isNearATop(CGPoint(x: 4000, y: 813), bars: bars))
        #expect(!ShownBarsCache.isNearATop(CGPoint(x: 4000, y: 814), bars: bars))
        // A bar taller than 40 points is near whole.
        let tall = [MenuBarGeometry(displayUUID: main, rect: CGRect(x: 0, y: 0, width: 1000, height: 52), notch: nil)]
        #expect(ShownBarsCache.isNearATop(CGPoint(x: 500, y: 52), bars: tall))
        // Not past the bar's sides.
        #expect(!ShownBarsCache.isNearATop(CGPoint(x: 3360, y: 10), bars: [bars[0]]))
    }

    @Test func aReadIsKeptForAQuarterOfASecond() {
        var cache = ShownBarsCache()
        let reads = WindowReads()
        reads.set([window(bars[0])])
        let point = CGPoint(x: 1500, y: 5)
        #expect(cache.shownBars(at: point, bars: bars, now: at(0), windows: reads.read) == [main])
        // A full-screen app takes the bar: the list changes, but a read this recent is what is answered.
        reads.set([])
        #expect(cache.shownBars(at: point, bars: bars, now: at(0.1), windows: reads.read) == [main])
        #expect(cache.shownBars(at: point, bars: bars, now: at(0.249), windows: reads.read) == [main])
        #expect(reads.count == 1)
        // A quarter of a second later it is read again.
        #expect(cache.shownBars(at: point, bars: bars, now: at(0.25), windows: reads.read).isEmpty)
        #expect(reads.count == 2)
        #expect(cache.shownBars(at: point, bars: bars, now: at(0.3), windows: reads.read).isEmpty)
        #expect(reads.count == 2)
    }

    @Test func theLastReadIsAnsweredWhenThePointerIsAway() {
        var cache = ShownBarsCache()
        let reads = WindowReads()
        reads.set([window(bars[0])])
        #expect(cache.shownBars(at: CGPoint(x: 1500, y: 5), bars: bars, now: at(0), windows: reads.read) == [main])
        // Far away, a long time later: no read, and the last answer, which is of no use where there is no bar.
        #expect(cache.shownBars(at: CGPoint(x: 1500, y: 600), bars: bars, now: at(60), windows: reads.read) == [main])
        #expect(reads.count == 1)
        // Back at the top, the answer is old, so it is read.
        reads.set([])
        #expect(cache.shownBars(at: CGPoint(x: 1500, y: 5), bars: bars, now: at(61), windows: reads.read).isEmpty)
        #expect(reads.count == 2)
    }

    @Test func otherBarsAreAnotherRead() {
        // The displays changed within the quarter of a second: what was read is for bars that aren't these.
        var cache = ShownBarsCache()
        let reads = WindowReads()
        reads.set([window(bars[0])])
        let point = CGPoint(x: 1500, y: 5)
        _ = cache.shownBars(at: point, bars: bars, now: at(0), windows: reads.read)
        let narrower = [MenuBarGeometry(displayUUID: main, rect: CGRect(x: 0, y: 0, width: 1728, height: 33), notch: nil)]
        reads.set([window(narrower[0])])
        #expect(cache.shownBars(at: point, bars: narrower, now: at(0.05), windows: reads.read) == [main])
        #expect(reads.count == 2)
    }

    @Test func aReadSomebodyElseTookIsNotTakenAgainAtOnce() {
        var cache = ShownBarsCache()
        let reads = WindowReads()
        cache.note(windows: [window(bars[1])], bars: bars, now: at(0))
        #expect(cache.shownBars(at: CGPoint(x: 4000, y: 780), bars: bars, now: at(0.2), windows: reads.read) == [other])
        #expect(reads.count == 0)
    }

    @Test func noBarsNothingIsRead() {
        var cache = ShownBarsCache()
        let reads = WindowReads()
        #expect(cache.shownBars(at: CGPoint(x: 10, y: 10), bars: [], now: start, windows: reads.read).isEmpty)
        #expect(reads.count == 0)
    }
}

@Suite("Menu bar takeover policy", .timeLimit(.minutes(1)))
struct MenuBarTakeoverPolicyTests {
    private let main = "display-main"
    private let other = "display-other"

    private var bars: [MenuBarGeometry] {
        [MenuBarGeometry(displayUUID: main, rect: CGRect(x: 0, y: 0, width: 3360, height: 30), notch: nil),
         MenuBarGeometry(displayUUID: other, rect: CGRect(x: 3360, y: 0, width: 1728, height: 33), notch: nil)]
    }

    @Test func aFullScreenAppsHiddenBarIsNothingToMakeRoomIn() {
        #expect(MenuBarTakeoverPolicy.skippedLogLine == "no menu bar to make room in")
        // The front app is full screen on the main display: its bar isn't on screen, the other display's is.
        #expect(!MenuBarTakeoverPolicy.hasBarToClear(frontDisplay: main, shownBars: [other], bars: bars))
        #expect(!MenuBarTakeoverPolicy.hasBarToClear(frontDisplay: main, shownBars: [], bars: bars))
    }

    @Test func aBarThatIsShownHasRoomToMake() {
        #expect(MenuBarTakeoverPolicy.hasBarToClear(frontDisplay: main, shownBars: [main, other], bars: bars))
        #expect(MenuBarTakeoverPolicy.hasBarToClear(frontDisplay: other, shownBars: [other], bars: bars))
    }

    @Test func withNoFrontDisplayAnyBarShownIsEnough() {
        #expect(MenuBarTakeoverPolicy.hasBarToClear(frontDisplay: nil, shownBars: [other], bars: bars))
        #expect(!MenuBarTakeoverPolicy.hasBarToClear(frontDisplay: nil, shownBars: [], bars: bars))
        // A display no bar is known for is the same.
        #expect(MenuBarTakeoverPolicy.hasBarToClear(frontDisplay: "display-unplugged", shownBars: [main], bars: bars))
    }

    @Test func withNoBarsThereIsNothing() {
        #expect(!MenuBarTakeoverPolicy.hasBarToClear(frontDisplay: main, shownBars: [main], bars: []))
    }

    @Test func takeoverThatDidNotActivateIsUndone() {
        #expect(MenuBarTakeoverPolicy.couldNotActivateLogLine == "couldn't become the front app to make room")
        // Mantel is the front app: the room is looked at again.
        #expect(MenuBarTakeoverPolicy.afterBegin(activated: true, overflowAlreadyLogged: false) == .recheckRoom)
        #expect(MenuBarTakeoverPolicy.afterBegin(activated: true, overflowAlreadyLogged: true) == .recheckRoom)
        // It never became the front app: the takeover is undone, and the icons are left in the « menu, said once.
        #expect(MenuBarTakeoverPolicy.afterBegin(activated: false, overflowAlreadyLogged: false) == .undo(.leaveOverflow(logOnce: true)))
        #expect(MenuBarTakeoverPolicy.afterBegin(activated: false, overflowAlreadyLogged: true) == .undo(.leaveOverflow(logOnce: false)))
    }

    @Test func mantelIsTheFrontAppOnlyWhileItHasTheMenuBar() {
        // Another app coming to the front is the front app.
        #expect(MenuBarTakeoverPolicy.reportsFrontApp(activated: 400, own: 100, takeoverActive: false))
        #expect(MenuBarTakeoverPolicy.reportsFrontApp(activated: 400, own: 100, takeoverActive: true))
        // Mantel's Settings window taking the focus leaves the menus on the bar as they were.
        #expect(!MenuBarTakeoverPolicy.reportsFrontApp(activated: 100, own: 100, takeoverActive: false))
        // Having taken the menu bar over, Mantel's menu is what is on it.
        #expect(MenuBarTakeoverPolicy.reportsFrontApp(activated: 100, own: 100, takeoverActive: true))
    }
}

@Suite("Dots copy", .timeLimit(.minutes(1)))
struct DotsCopyTests {
    @Test func theDotsAreNamedForWhatTheyShow() {
        #expect(DotsCopy.hiddenDotDescription == "Show hidden icons")
        #expect(DotsCopy.alwaysDotDescription == "Show all icons")
    }

    @Test func theTooltipSaysWhichWayOfHidingAndWhy() {
        let status = EngineStatus(kind: .allowlist, reason: "Chosen automatically: macOS's allowlist works.", degraded: false,
                                  availability: [:], lastError: nil)
        #expect(DotsCopy.tooltip(for: status) == "Hiding with Allowlist. Chosen automatically: macOS's allowlist works.")
        let spacer = EngineStatus(kind: .spacer, reason: "Chosen in Settings › Advanced.", degraded: true, availability: [:], lastError: nil)
        #expect(DotsCopy.tooltip(for: spacer) == "Hiding with Wide spacer. Chosen in Settings › Advanced.")
        let switches = EngineStatus(kind: .approvals, reason: "A call is active, so the mic indicator stays visible.", degraded: false,
                                    availability: [:], lastError: nil)
        #expect(DotsCopy.tooltip(for: switches) == "Hiding with System Settings switches. A call is active, so the mic indicator stays visible.")
    }

    @Test func theMenuUsesTitleCase() {
        #expect(DotsCopy.settingsItem == "Settings…")
        #expect(DotsCopy.focusModeItem == "Focus Mode")
        #expect(DotsCopy.refreshItem == "Refresh Menu Bar")
        #expect(DotsCopy.diagnosticsItem == "Diagnostics…")
        #expect(DotsCopy.quitItem == "Quit Mantel")
    }
}

@Suite("Commands and the reveal", .timeLimit(.minutes(1)))
struct CommandRevealsTests {
    @Test func showSaysHowMuchToShow() {
        #expect(RevealEvent.forShow(.hidden) == .show(.hidden))
        #expect(RevealEvent.forShow(.all) == .show(.all))
        #expect(RevealEvent.forShow(.nothing) == .show(.off))
        for target in ShowTarget.allCases { _ = RevealEvent.forShow(target) }
    }

    @Test func focusSaysWhatToDoToFocusMode() {
        #expect(RevealEvent.forFocus(.on) == .setFocusMode(true))
        #expect(RevealEvent.forFocus(.off) == .setFocusMode(false))
        #expect(RevealEvent.forFocus(.toggle) == .toggleFocusMode)
    }

    @Test func theMachineDoesWhatTheCommandsAsk() {
        // `show none` hides what is shown, whatever it is, and `show hidden` shows it; Focus Mode follows `focus`.
        var machine = RevealMachine(settings: RevealSettings())
        _ = machine.handle(.forShow(.all))
        #expect(machine.state == .allShown)
        _ = machine.handle(.forShow(.nothing))
        #expect(machine.state == .collapsed)
        _ = machine.handle(.forFocus(.on))
        #expect(machine.state == .focusMode)
        _ = machine.handle(.forFocus(.toggle))
        #expect(machine.state == .collapsed)
        _ = machine.handle(.forFocus(.off))
        #expect(machine.state == .collapsed)
        _ = machine.handle(.forFocus(.on))
        _ = machine.handle(.forShow(.hidden))
        #expect(machine.state == .hiddenShown, "a command leaves Focus Mode")
    }

    @Test func theEngineAnswerHasTheFiveKeys() {
        let status = EngineStatus(kind: .allowlist, reason: "Chosen automatically: macOS's allowlist works.", degraded: false,
                                  availability: [.allowlist: "available", .approvals: "needs permission: Choose the file", .spacer: "available"],
                                  lastError: "ignored")
        guard case .object(let object) = status.commandValue else {
            Issue.record("an object")
            return
        }
        #expect(Set(object.keys) == ["engine", "title", "reason", "degraded", "availability"])
        #expect(object["engine"] == .string("allowlist"))
        #expect(object["title"] == .string("Allowlist"))
        #expect(object["reason"] == .string("Chosen automatically: macOS's allowlist works."))
        #expect(object["degraded"] == .bool(false))
        #expect(object["availability"] == .object(["allowlist": .string("available"), "approvals": .string("needs permission: Choose the file"),
                                                   "spacer": .string("available")]))
    }

    @Test func theSpacerIsDegraded() {
        let status = EngineStatus(kind: .spacer, reason: "Why.", degraded: true, availability: [:], lastError: nil)
        guard case .object(let object) = status.commandValue else {
            Issue.record("an object")
            return
        }
        #expect(object["degraded"] == .bool(true))
        #expect(object["engine"] == .string("spacer"))
        #expect(object["availability"] == .object([:]))
    }
}
