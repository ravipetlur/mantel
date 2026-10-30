import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Synchronization

@testable import MKMenuBar

// The fakes of what clicking an icon reaches: the poster that sends clicks and keys, the locator that says where an item is, the presser
// that presses it and the relauncher that opens an app again. Each notes what it was asked and does what the test says. None of them reaches
// the real system: nothing is posted, no pointer moves, no Accessibility tree is read, no app is asked to quit.

/// A poster that posts nothing. `onClick` and `onKey` are where a test says what a click does in the fake world (a menu opens, a record is
/// written).
final class FakeClickPoster: ClickPosting {
    struct Click: Equatable, Sendable {
        let kind: ClickKind
        let point: CGPoint
    }

    struct Key: Equatable, Sendable {
        let code: UInt16
        let flags: CGEventFlags
    }

    private struct State {
        var clicks: [Click] = []
        var keys: [Key] = []
        var failure: ClickPostError?
        var onClick: (@Sendable (ClickKind, CGPoint) -> Void)?
        var onKey: (@Sendable (UInt16, CGEventFlags) -> Void)?
    }

    private let state = Mutex(State())

    var clicks: [Click] { state.withLock { $0.clicks } }
    var keys: [Key] { state.withLock { $0.keys } }

    /// Every click and key fails with this from now on (nil: they work).
    func fail(with error: ClickPostError?) { state.withLock { $0.failure = error } }
    func onClick(_ body: (@Sendable (ClickKind, CGPoint) -> Void)?) { state.withLock { $0.onClick = body } }
    func onKey(_ body: (@Sendable (UInt16, CGEventFlags) -> Void)?) { state.withLock { $0.onKey = body } }

    func click(_ kind: ClickKind, at point: CGPoint) throws(ClickPostError) {
        let outcome = state.withLock { state -> (failure: ClickPostError?, hook: (@Sendable (ClickKind, CGPoint) -> Void)?) in
            if state.failure == nil { state.clicks.append(Click(kind: kind, point: point)) }
            return (state.failure, state.onClick)
        }
        if let failure = outcome.failure { throw failure }
        outcome.hook?(kind, point)
    }

    func key(_ keyCode: UInt16, flags: CGEventFlags) throws(ClickPostError) {
        let outcome = state.withLock { state -> (failure: ClickPostError?, hook: (@Sendable (UInt16, CGEventFlags) -> Void)?) in
            if state.failure == nil { state.keys.append(Key(code: keyCode, flags: flags)) }
            return (state.failure, state.onKey)
        }
        if let failure = outcome.failure { throw failure }
        outcome.hook?(keyCode, flags)
    }
}

/// A locator that answers what a test says. Each item has an answer: a function of which call of the item's this is (counted from 1), so
/// that an item can be nowhere for a while and then in a slot, as it is while macOS draws it.
final class FakeItemLocator: ItemLocating {
    /// One call of `locate`.
    struct Call: Equatable, Sendable {
        let item: ItemID
        let display: String?
        let hadBaseline: Bool
        /// How many calls this item has had, this one included.
        let number: Int
    }

    typealias Answer = @Sendable (_ number: Int) -> ItemLocation?

    private struct State {
        var snapshot: SlotSnapshot?
        var snapshotsByDisplay: [String: SlotSnapshot] = [:]
        var snapshotCalls: [String?] = []
        var calls: [Call] = []
        var answers: [ItemID: Answer] = [:]
        var concealedApps: Set<String> = []
        var onSnapshot: (@Sendable () async -> Void)?
        var onLocate: (@Sendable (ItemID, Int) async -> Void)?
        var snapshotAnswer: (@Sendable (Int) -> SlotSnapshot?)?
        var baselines: [SlotSnapshot?] = []
    }

    private let state = Mutex(State())

    /// What `slotSnapshot` answers.
    func setSnapshot(_ snapshot: SlotSnapshot?) { state.withLock { $0.snapshot = snapshot } }
    /// What `slotSnapshot` answers for a display that is asked for by name (over `setSnapshot`'s).
    func setSnapshot(_ snapshot: SlotSnapshot, on display: String) { state.withLock { $0.snapshotsByDisplay[display] = snapshot } }
    /// What `slotSnapshot` answers, by the number of the call (counted from 1), over `setSnapshot`'s.
    func answerSnapshots(_ body: (@Sendable (Int) -> SlotSnapshot?)?) { state.withLock { $0.snapshotAnswer = body } }
    /// Run as a snapshot is taken (a test looks at the world then).
    func onSnapshot(_ body: (@Sendable () async -> Void)?) { state.withLock { $0.onSnapshot = body } }
    /// Run as a look at an item is answered, after the answer is told and before it is given (the bar changes during the look): with the item
    /// and the number of the call.
    func onLocate(_ body: (@Sendable (ItemID, Int) async -> Void)?) { state.withLock { $0.onLocate = body } }
    /// The apps the scanner would have among the concealed: as the scanner does, `locate` gives a bare tie of one of them as nothing.
    func setConcealedApps(_ apps: Set<String>) { state.withLock { $0.concealedApps = apps } }
    /// The baseline each call of `locate` was given, in order.
    var baselines: [SlotSnapshot?] { state.withLock { $0.baselines } }
    /// What `locate` answers for the item, by the number of the call.
    func answer(for item: ItemID, _ body: @escaping Answer) { state.withLock { $0.answers[item] = body } }
    /// The item is always in this slot.
    func place(_ location: ItemLocation) { answer(for: location.item) { _ in location } }
    /// The item is nowhere, as when it is concealed.
    func remove(_ item: ItemID) { answer(for: item) { _ in nil } }
    /// The item is nowhere for the first `calls` calls and then in this slot.
    func appear(_ location: ItemLocation, afterCalls calls: Int) {
        answer(for: location.item) { number in number > calls ? location : nil }
    }

    var calls: [Call] { state.withLock { $0.calls } }
    func calls(of item: ItemID) -> [Call] { calls.filter { $0.item == item } }
    var snapshotCallCount: Int { state.withLock { $0.snapshotCalls.count } }

    func slotSnapshot(on display: String?) async -> SlotSnapshot? {
        let taken = state.withLock { state -> (snapshot: SlotSnapshot?, hook: (@Sendable () async -> Void)?) in
            state.snapshotCalls.append(display)
            if let answer = state.snapshotAnswer { return (answer(state.snapshotCalls.count), state.onSnapshot) }
            return (display.flatMap { state.snapshotsByDisplay[$0] } ?? state.snapshot, state.onSnapshot)
        }
        await taken.hook?()
        return taken.snapshot
    }

    func locate(_ item: ItemID, on display: String?, since baseline: SlotSnapshot?) async -> ItemLocation? {
        let decided = state.withLock { state -> (answer: Answer?, number: Int, concealed: Bool, hook: (@Sendable (ItemID, Int) async -> Void)?) in
            let number = state.calls.filter { $0.item == item }.count + 1
            state.calls.append(Call(item: item, display: display, hadBaseline: baseline != nil, number: number))
            state.baselines.append(baseline)
            return (state.answers[item], number, state.concealedApps.contains(item.bundleID), state.onLocate)
        }
        let told = decided.answer?(decided.number)
        await decided.hook?(item, decided.number)
        guard let location = told else { return nil }
        if decided.concealed, location.tiedBy == .tie { return nil }
        // An item is on the display its slot is on, and nowhere on another.
        if let display, display != location.displayUUID { return nil }
        return location
    }

    /// A location for a test: by default a slot on the main display where the item's own frame and the new slot agree, so that a click may be
    /// posted at it for an item that was concealed.
    static func location(of item: ItemID, slot: CGRect, display: String = DisplayFixtures.deskMain.uuid,
                         tiedBy: ItemLocation.TiedBy = .tieAndNewSlots, wasInBaseline: Bool = false, widthAgrees: Bool = true,
                         frameMinusSlotWidth: CGFloat? = 2) -> ItemLocation {
        ItemLocation(item: item, displayUUID: display, slotFrame: slot, tiedBy: tiedBy, slotWasInBaseline: wasInBaseline,
                     widthAgrees: widthAgrees, frameMinusSlotWidth: frameMinusSlotWidth)
    }
}

/// A presser that presses nothing. `onPress` and `onShowMenu` are where a test says what a press does in the fake world.
final class FakeItemPresser: ItemPressing {
    private struct State {
        var pressed: [ItemID] = []
        var menus: [ItemID] = []
        var pressError: ItemPressError?
        var menuError: ItemPressError?
        var onPress: (@Sendable (ItemID) -> Void)?
        var onShowMenu: (@Sendable (ItemID) -> Void)?
    }

    private let state = Mutex(State())

    var pressed: [ItemID] { state.withLock { $0.pressed } }
    var menusShown: [ItemID] { state.withLock { $0.menus } }

    func failPress(with error: ItemPressError?) { state.withLock { $0.pressError = error } }
    func failShowMenu(with error: ItemPressError?) { state.withLock { $0.menuError = error } }
    func onPress(_ body: (@Sendable (ItemID) -> Void)?) { state.withLock { $0.onPress = body } }
    func onShowMenu(_ body: (@Sendable (ItemID) -> Void)?) { state.withLock { $0.onShowMenu = body } }

    func press(_ item: ItemID) async throws(ItemPressError) {
        try await press(item, issued: {})
    }

    /// The press is on record, and what it does in the fake world is done, before it is said to have been issued: the driver counts a press
    /// as sent a moment (on its clock) after that, and a click that is answered by then must find it among `pressed` and its menu open,
    /// however long the task that presses takes to run on a busy Mac.
    func press(_ item: ItemID, issued: @Sendable () -> Void) async throws(ItemPressError) {
        let outcome = state.withLock { state -> (error: ItemPressError?, hook: (@Sendable (ItemID) -> Void)?) in
            if state.pressError == nil { state.pressed.append(item) }
            return (state.pressError, state.onPress)
        }
        if outcome.error == nil { outcome.hook?(item) }
        issued()
        if let error = outcome.error { throw error }
    }

    func showMenu(_ item: ItemID) async throws(ItemPressError) {
        try await showMenu(item, issued: {})
    }

    /// As `press(_:issued:)`: on record, and done, before it is issued.
    func showMenu(_ item: ItemID, issued: @Sendable () -> Void) async throws(ItemPressError) {
        let outcome = state.withLock { state -> (error: ItemPressError?, hook: (@Sendable (ItemID) -> Void)?) in
            if state.menuError == nil { state.menus.append(item) }
            return (state.menuError, state.onShowMenu)
        }
        if outcome.error == nil { outcome.hook?(item) }
        issued()
        if let error = outcome.error { throw error }
    }
}

/// A relauncher that quits nothing and opens nothing: it notes the apps it was asked for, and does what the test says happens then.
final class FakeRelauncher: AppRelaunching {
    private struct State {
        var asked: [RelaunchCandidate] = []
        var outcome: RelaunchOutcome = .relaunched
        var onRelaunch: (@Sendable (RelaunchCandidate) -> Void)?
    }

    private let state = Mutex(State())

    /// The apps it was asked to relaunch, in order.
    var asked: [RelaunchCandidate] { state.withLock { $0.asked } }

    func respond(with outcome: RelaunchOutcome) { state.withLock { $0.outcome = outcome } }
    func onRelaunch(_ body: (@Sendable (RelaunchCandidate) -> Void)?) { state.withLock { $0.onRelaunch = body } }

    func relaunch(_ app: RelaunchCandidate) async -> RelaunchOutcome {
        let outcome = state.withLock { state -> (RelaunchOutcome, (@Sendable (RelaunchCandidate) -> Void)?) in
            state.asked.append(app)
            return (state.outcome, state.onRelaunch)
        }
        outcome.1?(app)
        return outcome.0
    }
}

/// What the test item is told by a notification, and what a test does when it hears one.
final class FakeTestItemNotifier: Sendable {
    private struct State {
        var sent: [String] = []
        var onNotify: (@Sendable (String) -> Void)?
    }

    private let state = Mutex(State())

    var sent: [String] { state.withLock { $0.sent } }
    func onNotify(_ body: (@Sendable (String) -> Void)?) { state.withLock { $0.onNotify = body } }

    func notify(_ command: String) {
        let hook = state.withLock { state -> (@Sendable (String) -> Void)? in
            state.sent.append(command)
            return state.onNotify
        }
        hook?(command)
    }
}

/// Where the pointer is, in a test: a value the test sets, and a poster that is made to move it can.
final class FakePointer: Sendable {
    private let location: Mutex<CGPoint?>

    init(_ location: CGPoint? = CGPoint(x: 1200, y: 400)) {
        self.location = Mutex(location)
    }

    var current: CGPoint? { location.withLock { $0 } }
    func move(to point: CGPoint?) { location.withLock { $0 = point } }
}
