import CoreGraphics
import Foundation
import MKCore
import MKLayout
import Synchronization

/// Where a request to click an icon came from.
public enum ClickOrigin: String, Sendable {
    case secondBar, groupPanel, commandBar, hotkey, command
}

/// One icon to click, and how.
public struct IconClickRequest: Sendable, Equatable {
    public let item: ItemID
    public let kind: ClickKind
    /// Where to look for the icon first: the panel's or the pointer's display. The icon is then looked for on the active display (the one the
    /// apps' frames are on, which is the main display's only when that is the active one); with nil, on the active display alone.
    public let display: String?
    public let origin: ClickOrigin

    public init(item: ItemID, kind: ClickKind, display: String?, origin: ClickOrigin) {
        self.item = item
        self.kind = kind
        self.display = display
        self.origin = origin
    }
}

/// How an icon was clicked.
public enum IconClickRoute: String, Codable, Sendable {
    /// The icon was drawn and was pressed (Accessibility).
    case pressedDrawn
    /// The icon was drawn and a click was posted at its slot.
    case postedDrawn
    /// The icon had no room (or wasn't to be waited for) and was pressed where it is: its menu opens on screen.
    case pressedInPlace
    /// `AXShowMenu` opened the icon's menu.
    case shownMenu
    /// Shown apps were concealed to make room, and the icon was pressed.
    case madeRoomThenPressed
    /// Shown apps were concealed to make room, and a click was posted at the icon's slot.
    case madeRoomThenPosted
}

public enum IconClickOutcome: Sendable, Equatable {
    case clicked(IconClickRoute)
    case failed(IconClickFailure)
    /// A newer click took over, or the caller was cancelled, before this one was sent: **nothing was sent**, and the click's reveal has ended.
    /// It isn't a failure to tell the person of (the newer click is the one that counts): callers don't toast it.
    case overtaken
}

public enum IconClickFailure: Sendable, Equatable {
    /// The icon has no room on the bar and none could be made (nothing more can be concealed), and it can't be pressed where it is.
    case noRoom
    /// The icon's app (or macOS) didn't take the press; the text says why, in a few words.
    case refused(String)
    /// The icon is on a bar that isn't on screen (a full-screen app has the display).
    case hiddenBar
    case notRunning
    /// The icon can't be reached: nothing draws it, it can't be told to be where a slot is, the bar is changing or being changed, or the way
    /// to click it isn't there. Nothing was posted.
    case unreachable
}

/// Clicks one icon wherever it is: shown, hidden, or with no room on the bar. The click is **never posted at a slot that isn't the item's**:
/// a post needs a location that `ItemLocation.isPostable` accepts, taken from a look at a bar that was still and drawn (the apps that were
/// asked for are drawn some time after their plan is applied, and what is read of the bar before is not what will be there), and when the
/// item can't be told to be where it is, it is pressed where it is (Accessibility finds the item by its own list, not by a place) or the
/// answer is that it couldn't be reached.
///
/// The icon is asked for (`MenuBarSession.revealIcons`) and clicked as soon as it is drawn; the answer is returned when the click is sent.
/// What follows is the driver's own: the icon's menu is watched, and the room that was made for the click is given back once the menu is
/// closed, and the icon is put away again (`endIconReveal`) once the delay to rehide has passed, never under an open menu. A newer click
/// ends the earlier one's reveal, and the room, at once, whatever it is doing.
public actor IconClickDriver {
    /// How often the icon is looked for while it is waited for to be drawn.
    static let drawnPoll: Duration = .milliseconds(50)
    /// How long a press is waited for, from when it is issued, to show that it was sent: a press that opens a menu doesn't return until the
    /// menu closes (it gives up after about 260 ms), and the answer isn't held that long.
    static let pressSentWait: Duration = .milliseconds(300)
    /// The most a reveal is held for a delay that never ends, or a menu that isn't seen to close.
    static let longestHold: Duration = .seconds(600)
    /// The most the bar is waited on to be still (no plan under way, the last one drawn) before the click gives up looking at it.
    static let settleLimit: Duration = .seconds(5)
    /// How many times the bar is looked at again, for a click that is about to be posted, when it changed since the look that found the icon.
    static let fenceLooks = 3
    /// The rounds of room made for an icon (`SwapCalculator.maximumRounds`).
    static let roomRounds = SwapCalculator.maximumRounds

    private let session: MenuBarSession
    private let locator: any ItemLocating
    private let presser: any ItemPressing
    private let poster: any ClickPosting
    private let windows: any WindowListReading
    private let pidOf: @Sendable (String) async -> pid_t?
    private let pointerInBar: @Sendable () -> Bool
    private let clock: any Clock
    private let rules: ClickRouteRules
    private let rehide: @Sendable () -> RehideDelay
    private let captured: @Sendable (ItemLocation) async -> Void

    /// Bumped by every click: one that finds it isn't the latest has been taken over.
    private var generation = 0
    /// The reveal of the click that is under way, before its menu is watched.
    private var live: (generation: Int, ticket: IconRevealTicket)?
    /// What watches the menu of the click that was sent, and puts the icon away afterwards.
    private var tail: (task: Task<Void, Never>, ticket: IconRevealTicket)?
    private var shows: [ItemID: (task: Task<Void, Never>, ticket: IconRevealTicket)] = [:]
    /// Mouse-downs the app saw (for the menu watch where menus aren't seen).
    private var mouseDowns: [CGPoint] = []
    private var loggedKinds: Set<ClickKind> = []

    /// `pidOf` is the process whose windows are the menu of an app's icon (a system item's is Control Center's: `com.apple.controlcenter`);
    /// nil asks the session (`MenuBarSession.extrasOwnerPID`), which knows which of an app's processes owns its items.
    public init(session: MenuBarSession, locator: any ItemLocating, presser: any ItemPressing, poster: any ClickPosting,
                windows: any WindowListReading, pidOf: (@Sendable (String) async -> pid_t?)? = nil,
                pointerInBar: @escaping @Sendable () -> Bool, clock: any Clock, rules: ClickRouteRules,
                rehide: @escaping @Sendable () -> RehideDelay, captured: @escaping @Sendable (ItemLocation) async -> Void) {
        self.session = session
        self.locator = locator
        self.presser = presser
        self.poster = poster
        self.windows = windows
        self.pidOf = pidOf ?? { [session] bundleID in await session.extrasOwnerPID(ofApp: bundleID) }
        self.pointerInBar = pointerInBar
        self.clock = clock
        self.rules = rules
        self.rehide = rehide
        self.captured = captured
    }

    // MARK: Clicking

    /// Returns once the click is sent or has failed. `beforeClick` runs after the icon-reveal plan is applied and before the click
    /// is sent: the panel closes there.
    public func click(_ request: IconClickRequest, beforeClick: @escaping @Sendable () async -> Void = {}) async -> IconClickOutcome {
        generation += 1
        let mine = generation
        await endCurrent()
        guard stillMine(mine) else { return .overtaken }

        let item = request.item
        // An option click arrives as a plain left click where macOS says so: it is a left click everywhere (pressed in place when the icon
        // isn't drawn, and no room is made for it).
        var kind = request.kind
        if kind == .option, !rules.postedOptionWorks {
            kind = .left
            if loggedKinds.insert(.option).inserted {
                Log.info("click", "a posted option click arrives as a left click here; doing a left click (app=\(item.isSystem ? "system" : item.bundleID))")
            }
        }

        // The app isn't running: nothing to click.
        if !item.isSystem, await pidOf(item.bundleID) == nil {
            let listed = await session.hasItems(ofApp: item.bundleID)
            if !listed { return .failed(.notRunning) }
        }
        // An icon that the app doesn't list now (a record of one that was never there, or isn't any more): nothing is revealed for it, and
        // nothing is pressed.
        if !item.isSystem, await session.hasNoSuchIcon(item) {
            Log.info("click", "\(item.bundleID) has no such icon now")
            return .failed(.unreachable)
        }
        // A system icon that is hidden is never drawn by a reveal (macOS doesn't): it can't be reached, and waiting for it would only wait.
        if item.isSystem {
            let hidden = await session.planConceals(item)
            if hidden { return .failed(.unreachable) }
        }
        // An app with an icon macOS doesn't tie to it never draws under the allowlist, so there is nothing to wait for and no room to make
        // for it: a left click presses it where it is, anything else can't be reached.
        let flagged = item.isSystem ? false : await session.isUnattached(item.bundleID)
        if flagged, kind != .left || !rules.pressWorksUndrawn { return .failed(.unreachable) }

        // What is drawn now, and whether the item is (an item that is drawn is clicked by its tie; one that isn't needs more). The bar is
        // looked at only when it is still: the apps a plan asked for are drawn up to `drawnWait` after it was applied, and what is read before
        // is the bar as it was.
        let looksAtTheBar = rules.locateWorks && !flagged
        var settled = true
        if looksAtTheBar {
            // An app the last plan has just shown is the slowest to be drawn, and what it left behind lies in a slot till then.
            let justShown = item.isSystem ? false : await session.concealedBeforeThePlan.contains(item.bundleID)
            switch await settleBar(mine, wait: justShown ? rules.justShownWait : rules.drawnWait) {
            case .settled: break
            case .notSettled: settled = false
            case .overtaken: return .overtaken
            }
        }
        let displays = looksAtTheBar && settled ? await lookDisplays(for: request) : []
        var snapshots: [String?: SlotSnapshot] = [:]
        var drawnAtSnapshot: Set<String?> = []
        if looksAtTheBar, settled {
            for display in displays { snapshots[display] = await locator.slotSnapshot(on: display) }
            let concealed = await session.planConceals(item)
            if !concealed {
                for display in displays {
                    guard let found = await locator.locate(item, on: display, since: nil) else { continue }
                    let state = await session.slotState(of: found)
                    if found.isPostable(drawnAtSnapshot: true), state == .drawn { drawnAtSnapshot.insert(display) }
                }
            }
        }
        guard stillMine(mine) else { return .overtaken }
        // Without a snapshot of any display (no grant, or MenuBarAgent isn't there) nothing can be posted: a right click can't be reached,
        // and nothing is revealed or waited for to find that out.
        if looksAtTheBar, settled, snapshots.isEmpty, kind != .left { return .failed(.unreachable) }

        let ticket = await session.revealIcons([item])
        guard stillMine(mine) else {
            await session.endIconReveal(ticket)
            return .overtaken
        }
        live = (mine, ticket)
        await beforeClick()
        guard stillMine(mine) else {
            await session.endIconReveal(ticket)
            return .overtaken
        }

        // What a post is fenced against: the bar as it is with the click's own plans in.
        let mark = await session.barChanges
        let route = Route(driver: self, request: request, kind: kind, mine: mine, ticket: ticket, displays: displays, snapshots: snapshots,
                          drawnAtSnapshot: drawnAtSnapshot, mark: mark)
        let outcome: IconClickOutcome
        if flagged {
            outcome = await press(route, as: .pressedInPlace, slot: nil)
        } else if !looksAtTheBar || !settled {
            // The bar can't be told (or isn't still): nothing is posted. What presses and asks the item for its menu doesn't need it.
            outcome = await clickWithoutLocating(route)
        } else {
            outcome = await clickLocating(route)
        }
        switch outcome {
        case .clicked:
            break
        case .failed, .overtaken:
            // Nothing is out, or the click failed: the reveal ends at once (the watch of a press that was refused ends it as it stops).
            if live?.generation == mine { live = nil }
            if let watching = tail, watching.ticket == ticket {
                tail = nil
                watching.task.cancel()
                await watching.task.value
            }
            await session.endIconReveal(ticket)
        }
        return outcome
    }

    /// Shows the icon without clicking, for the rehide delay (or until `endShows`). A second `show` of the same item restarts its delay.
    public func show(_ item: ItemID) async {
        let ticket = await session.revealIcons([item])
        let earlier = shows[item]
        let task = Task { [self] in
            await waitOutTheRehideDelay()
            await endShow(item, ticket: ticket)
        }
        shows[item] = (task, ticket)
        if let earlier {
            earlier.task.cancel()
            await session.endIconReveal(earlier.ticket)
        }
    }

    /// Puts away every icon `show` showed.
    public func endShows() async {
        let all = shows
        shows = [:]
        for (_, show) in all {
            show.task.cancel()
            await session.endIconReveal(show.ticket)
        }
    }

    /// For the menu watch where menus aren't seen: a mouse-down the app saw, in CoreGraphics global points.
    public func mouseDown(at point: CGPoint) async {
        mouseDowns.append(point)
    }

    private func endShow(_ item: ItemID, ticket: IconRevealTicket) async {
        // A show that was restarted or ended has been taken out of the table already.
        guard shows[item]?.ticket == ticket else { return }
        shows[item] = nil
        await session.endIconReveal(ticket)
    }

    /// The earlier click's reveal and watch end at once.
    private func endCurrent() async {
        if let live {
            self.live = nil
            await session.endIconReveal(live.ticket)
        }
        if let tail {
            self.tail = nil
            tail.task.cancel()
            await tail.task.value
        }
    }

    /// Whether the click is still the latest, and its caller hasn't gone.
    private func stillMine(_ mine: Int) -> Bool {
        mine == generation && !Task.isCancelled
    }

    // MARK: Waiting

    private enum Settled {
        case settled, notSettled, overtaken
    }

    /// Waits until the bar is still: no plan is being applied, and the last one was applied `wait` ago (`drawnWait`, unless the app is one
    /// that plan just showed): it is drawn on screen some time after, and the apps it shows or conceals are on their way until then. Gives
    /// up after `settleLimit`.
    private func settleBar(_ mine: Int, wait: Duration? = nil) async -> Settled {
        let wait = wait ?? rules.drawnWait
        let began = clock.now()
        while true {
            guard stillMine(mine) else { return .overtaken }
            let progress = await session.applyProgress
            if !progress.underway {
                guard let since = progress.since, since < wait else { return .settled }
            }
            guard clock.now().timeIntervalSince(began) < Self.seconds(Self.settleLimit) else { return .notSettled }
            do { try await clock.sleep(for: Self.drawnPoll) } catch { return .overtaken }
        }
    }

    /// Where the icon is looked for: where the request says, and then on the active display (the one whose bar the apps' frames are on).
    private func lookDisplays(for request: IconClickRequest) async -> [String?] {
        let active = await session.activeDisplay
        guard let first = request.display else { return [active] }
        return active.map { $0 == first ? [first] : [first, $0] } ?? [first]
    }

    /// What a look at the icon found.
    private struct Looked {
        var location: ItemLocation?
        var state: IconSlotState?
        var isDrawn = false
        var overtaken = false
        /// Milliseconds from the start of the look.
        var drawnMs: Double?
    }

    /// Looks for the item every 50 ms for `drawnWait`: it counts as drawn when it is located on a shown bar and not out of the way, and (for
    /// an item that wasn't drawn at the snapshot) the location can be posted at (`isPostable`): a tie alone may be a frame the app left
    /// behind.
    private func lookUntilDrawn(_ route: Route, snapshots: [String?: SlotSnapshot]) async -> Looked {
        var looked = Looked()
        let began = clock.now()
        while true {
            guard stillMine(route.mine) else {
                looked.overtaken = true
                return looked
            }
            for display in route.displays {
                guard let location = await locator.locate(route.item, on: display, since: snapshots[display]) else { continue }
                let state = await session.slotState(of: location)
                // A location in a drawn slot is what the answer is told by, over one that is out of the way or elsewhere.
                if looked.location == nil || (state == .drawn && looked.state != .drawn) {
                    looked.location = location
                    looked.state = state
                }
                if state == .drawn, location.isPostable(drawnAtSnapshot: route.drawnAtSnapshot.contains(display)) {
                    looked.location = location
                    looked.state = state
                    looked.isDrawn = true
                    looked.drawnMs = clock.now().timeIntervalSince(began) * 1000
                    return looked
                }
            }
            guard clock.now().timeIntervalSince(began) < Self.seconds(rules.drawnWait) else { return looked }
            do { try await clock.sleep(for: Self.drawnPoll) } catch {
                looked.overtaken = true
                return looked
            }
        }
    }

    // MARK: Sending

    /// The click of one request, step by step: the state is the driver's, and a `Route` is one click's walk through it.
    private struct Route {
        let driver: IconClickDriver
        let request: IconClickRequest
        /// What is clicked: the request's kind, a left click for an option click that arrives as one.
        let kind: ClickKind
        let mine: Int
        let ticket: IconRevealTicket
        /// The displays the icon is looked for on, in order.
        let displays: [String?]
        /// The slots that were drawn on each of them when the click began.
        let snapshots: [String?: SlotSnapshot]
        /// The displays on which the item was drawn at the snapshot.
        let drawnAtSnapshot: Set<String?>
        /// `MenuBarSession.barChanges` once the click's own plans were in (the icon's reveal, and each round of room, settled): a post is
        /// fenced against it, so that a plan that comes after, wherever it falls in the look, is looked at again.
        var mark: Int

        var item: ItemID { request.item }
    }

    /// Where an item can't be located (the rules say so, or the bar wasn't still): nothing is posted. A left click presses in place, or after
    /// room was made for it; a right click asks the item for its menu.
    private func clickWithoutLocating(_ route: Route) async -> IconClickOutcome {
        switch route.kind {
        case .left:
            if rules.whenNotDrawn == .pressInPlace { return await press(route, as: .pressedInPlace, slot: nil) }
            var made = false
            for round in 0..<Self.roomRounds {
                if await session.roomPredicted(for: route.ticket) { break }
                guard stillMine(route.mine), await session.makeRoom(for: route.ticket, round: round) else { break }
                made = true
            }
            guard stillMine(route.mine) else { return .overtaken }
            guard await session.roomPredicted(for: route.ticket) else { return .failed(.noRoom) }
            return await press(route, as: made ? .madeRoomThenPressed : .pressedInPlace, slot: nil)
        case .right:
            guard rules.showMenuWorks else { return .failed(.unreachable) }
            guard stillMine(route.mine) else { return .overtaken }
            return await showMenu(route)
        case .option:
            return .failed(.unreachable)
        }
    }

    private func clickLocating(_ route: Route) async -> IconClickOutcome {
        var route = route
        var looked = await lookUntilDrawn(route, snapshots: route.snapshots)
        if looked.overtaken { return .overtaken }
        if looked.isDrawn { return await clickFound(route, looked, snapshots: route.snapshots, madeRoom: false) }

        // Not drawn.
        var onHiddenBar = looked.state == .onHiddenBar
        if !onHiddenBar, looked.location == nil {
            var hidden = !route.displays.isEmpty
            for display in route.displays {
                let isHidden = await session.isBarHidden(on: display)
                if !isHidden { hidden = false }
            }
            onHiddenBar = hidden
        }
        if onHiddenBar {
            guard route.kind == .left, rules.pressWorksUndrawn else { return .failed(.hiddenBar) }
            return await press(route, as: .pressedInPlace, slot: nil)
        }
        if route.kind == .left, rules.whenNotDrawn == .pressInPlace {
            return await press(route, as: .pressedInPlace, slot: nil)
        }
        // The icon is in a drawn slot that can't be told to be its (a frame its app left behind, say): nothing is posted there, and no room
        // would be what it lacks.
        if looked.state == .drawn { return .failed(.unreachable) }

        // Make room, a round at a time, and look after each. What a look is compared with is the bar as it was without the apps that were
        // concealed for the room, which is told from the slots' owners at the snapshot (the apps' places can't be told apart otherwise).
        // Each round takes its apps out of the last round's baseline: an app concealed in a later round is on its way off from where the
        // earlier rounds moved it, and that is where its slot is kept as never new.
        var snapshots = route.snapshots
        for round in 0..<Self.roomRounds {
            guard stillMine(route.mine), await session.makeRoom(for: route.ticket, round: round) else { break }
            // The apps concealed for room are drawn on their way off the bar for some time: the bar is looked at once it is still, or what
            // is still drawn of one would look like the slot that appeared.
            switch await settleBar(route.mine) {
            case .settled: break
            case .notSettled: return .failed(.unreachable)
            case .overtaken: return .overtaken
            }
            route.mark = await session.barChanges
            let room = await session.roomConcealed(for: route.ticket)
            var without: [String?: SlotSnapshot] = [:]
            for (display, snapshot) in snapshots {
                guard let removed = snapshot.removing(apps: room) else { return .failed(.unreachable) }
                without[display] = removed
            }
            snapshots = without
            looked = await lookUntilDrawn(route, snapshots: snapshots)
            if looked.overtaken { return .overtaken }
            if looked.isDrawn { return await clickFound(route, looked, snapshots: snapshots, madeRoom: true) }
        }
        guard stillMine(route.mine) else { return .overtaken }
        if route.kind == .left, rules.pressWorksUndrawn {
            Log.info("click", "no room to draw \(route.item.bundleID); pressed it where it is")
            return await press(route, as: .pressedInPlace, slot: nil)
        }
        if looked.state == .drawn { return .failed(.unreachable) }
        // No room is the answer when the icon lacks it: out of the way, or overflowed, with nothing more to conceal. When the bar has room,
        // the icon can't be told (no Accessibility, an app macOS has turned off) and it couldn't be reached.
        let overflowed = await session.isOverflowed(route.item)
        let lacksRoom = looked.state == .outOfTheWay || overflowed
        return .failed(lacksRoom ? .noRoom : .unreachable)
    }

    /// The icon was found drawn at `found.location`. A click that is posted lands on whatever is in the slot then, so the bar is looked at
    /// again when it was changed since the look, and nothing is posted while it is being changed or something else holds the pointer.
    private func clickFound(_ route: Route, _ found: Looked, snapshots: [String?: SlotSnapshot], madeRoom: Bool) async -> IconClickOutcome {
        var looked = found
        var mark = route.mark
        for _ in 0..<Self.fenceLooks {
            guard looked.isDrawn, let location = looked.location else { return .failed(.unreachable) }
            guard stillMine(route.mine) else { return .overtaken }
            let (method, _) = clickMethod(for: route.kind)
            guard method == .post else { return await clickDrawn(route, at: location, madeRoom: madeRoom, drawnMs: looked.drawnMs) }
            switch await session.clickFence(since: mark) {
            case .clear:
                return await clickDrawn(route, at: location, madeRoom: madeRoom, drawnMs: looked.drawnMs)
            case .blocked:
                // The bar is moving or the pointer isn't the click's: a press in place doesn't need either.
                guard route.kind == .left, rules.pressWorksUndrawn else { return .failed(.unreachable) }
                return await press(route, as: .pressedInPlace, slot: nil)
            case .barChanged:
                // Whatever changed the bar is drawn some time after: it is waited for, and the icon looked for again.
                switch await settleBar(route.mine) {
                case .settled: break
                case .notSettled: return .failed(.unreachable)
                case .overtaken: return .overtaken
                }
                mark = await session.barChanges
                looked = await lookUntilDrawn(route, snapshots: snapshots)
                if looked.overtaken { return .overtaken }
            }
        }
        return .failed(.unreachable)
    }

    /// How a click of this kind reaches an icon that is drawn, and the kind that is posted: a left click presses or posts by the rules; right
    /// and option post at the slot's centre, or, where a posted click of that kind arrives as another, do a left click.
    private func clickMethod(for kind: ClickKind) -> (method: LeftClickMethod, postKind: ClickKind) {
        if kind == .left { return (rules.leftClick, .left) }
        if rules.postedKindWorks(kind) { return (.post, kind) }
        return (rules.leftClick, .left)
    }

    /// The icon is drawn at `location`, which can be posted at: a left click presses or posts by the rules; right and option post at the
    /// slot's centre, or, where a posted click of that kind arrives as another, do a left click (and say so once).
    private func clickDrawn(_ route: Route, at location: ItemLocation, madeRoom: Bool, drawnMs: Double?) async -> IconClickOutcome {
        let kind = route.kind
        let (method, postKind) = clickMethod(for: kind)
        if kind != .left, !rules.postedKindWorks(kind), loggedKinds.insert(kind).inserted {
            Log.info("click", "a posted \(kind.rawValue) click arrives as a left click here; doing a left click (app=\(route.item.isSystem ? "system" : route.item.bundleID))")
        }
        let outcome: IconClickOutcome
        switch method {
        case .press:
            outcome = await press(route, as: madeRoom ? .madeRoomThenPressed : .pressedDrawn, slot: location.slotFrame, drawnMs: drawnMs)
        case .post:
            outcome = await post(route, postKind, at: location, as: madeRoom ? .madeRoomThenPosted : .postedDrawn, drawnMs: drawnMs)
        }
        // The picture of the icon is taken for a click that was sent, never one that failed or was overtaken.
        if case .clicked = outcome {
            let captured = captured
            Task.detached { await captured(location) }
        }
        return outcome
    }

    /// Posts a click at the slot's centre. Nothing is posted when a newer click has taken over.
    private func post(_ route: Route, _ kind: ClickKind, at location: ItemLocation, as outcome: IconClickRoute,
                      drawnMs: Double?) async -> IconClickOutcome {
        guard stillMine(route.mine) else { return .overtaken }
        let point = CGPoint(x: location.slotFrame.midX, y: location.slotFrame.midY)
        let poster = poster
        let error = await Task.detached { () -> ClickPostError? in
            do throws(ClickPostError) {
                try poster.click(kind, at: point)
                return nil
            } catch {
                return error
            }
        }.value
        if let error { return .failed(.refused(error.localizedDescription)) }
        startWatching(route, slot: location.slotFrame, route: outcome, drawnMs: drawnMs, press: nil)
        return .clicked(outcome)
    }

    /// Presses the item. The watch of its menu starts before the press does, and runs while the press is out: a press that opens a menu
    /// doesn't return until the menu closes (or gives up, after about 260 ms), and the menu is seen at about 60 ms.
    ///
    /// `slot` is where the icon is drawn, and is given only for a drawn one (a menu near it is the icon's): never a slot that failed the test
    /// of being the item's.
    private func press(_ route: Route, as outcome: IconClickRoute, slot: CGRect?, drawnMs: Double? = nil) async -> IconClickOutcome {
        guard stillMine(route.mine) else { return .overtaken }
        let flight = Flight()
        startWatching(route, slot: slot, route: outcome, drawnMs: drawnMs, press: flight)
        let item = route.item, presser = presser
        Task.detached {
            do throws(ItemPressError) {
                try await presser.press(item, issued: { flight.issue() })
                flight.finish(nil)
            } catch {
                flight.finish(error)
            }
        }
        return await sent(route, flight: flight, as: outcome)
    }

    private func showMenu(_ route: Route) async -> IconClickOutcome {
        guard stillMine(route.mine) else { return .overtaken }
        let flight = Flight()
        startWatching(route, slot: nil, route: .shownMenu, drawnMs: nil, press: flight)
        let item = route.item, presser = presser
        Task.detached {
            do throws(ItemPressError) {
                try await presser.showMenu(item, issued: { flight.issue() })
                flight.finish(nil)
            } catch {
                flight.finish(error)
            }
        }
        return await sent(route, flight: flight, as: .shownMenu)
    }

    /// Waits until the action was sent: it returned, the menu it opened is seen, or the time a press is given has passed since it was issued
    /// (finding the item in its app's list comes first, and can take a while). An action that failed outright (the item isn't there, the app
    /// refused) is the answer.
    private func sent(_ route: Route, flight: Flight, as outcome: IconClickRoute) async -> IconClickOutcome {
        let clock = clock
        let timer = Task {
            await flight.issued.wait()
            do { try await clock.sleep(for: Self.pressSentWait) } catch { return }
            flight.markSent()
        }
        await flight.sent.wait()
        timer.cancel()
        if let error = flight.error, let failure = Self.failure(for: error) {
            return .failed(failure)
        }
        return .clicked(outcome)
    }

    /// What a failed action means for the caller; nil for one that may have been sent all the same (it timed out while a menu tracks).
    private static func failure(for error: ItemPressError) -> IconClickFailure? {
        switch error {
        case .noAnswer: nil
        case .notFound, .noShowMenu: .unreachable
        case .refused(let text): .refused(text)
        case .notTrusted: .refused(error.localizedDescription)
        }
    }

    // MARK: The menu

    /// Something that waits can wait for, and that a cancelled waiter doesn't keep waiting for.
    private final class Latch: Sendable {
        private struct State {
            var isOpen = false
            var next: UInt64 = 0
            var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        }

        private let state = Mutex(State())

        func open() {
            let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.isOpen = true
                defer { state.waiters = [:] }
                return Array(state.waiters.values)
            }
            for waiter in waiters { waiter.resume() }
        }

        func wait() async {
            let id = state.withLock { state -> UInt64 in
                state.next += 1
                return state.next
            }
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let ready = state.withLock { state -> Bool in
                        if state.isOpen || Task.isCancelled { return true }
                        state.waiters[id] = continuation
                        return false
                    }
                    if ready { continuation.resume() }
                }
            } onCancel: {
                let continuation = state.withLock { $0.waiters.removeValue(forKey: id) }
                continuation?.resume()
            }
        }
    }

    /// A press or `AXShowMenu` that was sent and may not have returned.
    private final class Flight: Sendable {
        /// Opens when the action is issued (the item found in its app's list, the action about to go out), or when it failed before that.
        let issued = Latch()
        /// Opens when the action is known to have been sent: it returned, a menu opened, or it has been out as long as it is waited for.
        let sent = Latch()
        private let failure = Mutex<ItemPressError?>(nil)

        /// The error the action came back with, once it has.
        var error: ItemPressError? { failure.withLock { $0 } }

        func issue() { issued.open() }

        /// The action returned, with this error or none.
        func finish(_ error: ItemPressError?) {
            failure.withLock { $0 = error }
            issued.open()
            sent.open()
        }

        func markSent() { sent.open() }
    }

    /// Starts the task that watches the menu of the click that is sent (or about to be) and puts the icon away after it.
    private func startWatching(_ route: Route, slot: CGRect?, route outcome: IconClickRoute, drawnMs: Double?, press: Flight?) {
        let ticket = route.ticket, item = route.item, started = clock.now()
        if live?.generation == route.mine { live = nil }
        let task = Task { [self] in
            await watchMenu(item: item, ticket: ticket, slot: slot, started: started, route: outcome, drawnMs: drawnMs, press: press)
        }
        tail = (task, ticket)
    }

    /// Reads the window list every 200 ms through `ClickMenuWatch`, until the menu has closed (or none opened by the timeout), then gives
    /// back the room that was made for the click, waits the rehide delay with no menu open, then ends the reveal. Ends it at once when
    /// cancelled, when the press turns out to have failed after it was answered, and when the menu is still there after `longestHold`.
    private func watchMenu(item: ItemID, ticket: IconRevealTicket, slot: CGRect?, started: Date, route: IconClickRoute, drawnMs: Double?,
                           press: Flight?) async {
        let ownerBundle = item.isSystem ? "com.apple.controlcenter" : item.bundleID
        let deadline = rules.menusAreSeen ? ClickRouteRules.menuAppearWait : Self.longestHold
        var watch = ClickMenuWatch(startedAt: started, menusAreSeen: rules.menusAreSeen)
        var menuMs: Double?
        var timeoutSent = false
        var closedAt: Date?
        var endsAtOnce = false
        mouseDowns = []
        while !Task.isCancelled {
            let now = clock.now()
            // A press that failed after the click was answered (it took long to find the item): no menu is coming.
            if let error = press?.error, Self.failure(for: error) != nil {
                Log.info("click", "the press failed after it was answered (app=\(item.isSystem ? "system" : item.bundleID)): \(error.localizedDescription)")
                endsAtOnce = true
                break
            }
            let list = windows.onScreenWindows()
            let pid = await pidOf(ownerBundle)
            let ofApp = list.contains { window in
                guard window.alpha > 0, window.layer >= rules.menuMinimumLayer else { return false }
                if let pid, window.ownerPID == pid { return true }
                return slot.map { ClickMenuRules.isNearItem(window.bounds, slot: $0) } ?? false
            }
            var phase = watch.handle(.poll(menuOfApp: ofApp, anyMenuOpen: WindowRules.isMenuOpen(list), pointerInBar: pointerInBar(), at: now))
            for point in mouseDowns where slot.map({ !$0.contains(point) }) ?? true {
                phase = watch.handle(.mouseDownOutsideIcon(at: now))
            }
            mouseDowns = []
            if phase == .menuOpen, menuMs == nil {
                menuMs = now.timeIntervalSince(started) * 1000
                press?.markSent()
            }
            if case .menuClosed(let at) = phase {
                closedAt = at
                break
            }
            // Whatever holds the watch (a menu that is never seen to close, a window of the app up, the pointer resting in the bar) holds it
            // no longer than this.
            if now.timeIntervalSince(started) >= Self.seconds(Self.longestHold) {
                Log.info("click", "the menu was held for the longest a reveal is held; putting the icon away")
                endsAtOnce = true
                break
            }
            if !timeoutSent, now.timeIntervalSince(started) >= Self.seconds(deadline) {
                timeoutSent = true
                if case .menuClosed(let at) = watch.handle(.timeout(at: now)) {
                    closedAt = at
                    break
                }
            }
            do { try await clock.sleep(for: ClickRouteRules.menuPoll) } catch { break }
        }
        Log.info("click", "route=\(route.rawValue) app=\(item.isSystem ? "system" : item.bundleID) drawnMs=\(drawnMs.map { String(Int($0)) } ?? "none") menuMs=\(menuMs.map { String(Int($0)) } ?? "none")")
        if !Task.isCancelled, !endsAtOnce, closedAt != nil {
            // The room made for the click goes back with the menu it was made for; the icon itself stays for the rehide delay.
            await session.giveBackRoom(for: ticket)
            await waitOutTheRehideDelay()
            await waitForNoMenu()
        }
        if tail?.ticket == ticket { tail = nil }
        await session.endIconReveal(ticket)
    }

    /// The rehide delay: seconds, or (for `.never`) until the reveal machine next collapses, at the most ten minutes. Returns at once when
    /// cancelled.
    private func waitOutTheRehideDelay() async {
        switch rehide() {
        case .seconds(let seconds):
            try? await clock.sleep(for: .seconds(seconds))
        case .never:
            let mark = await session.revealMark
            let began = clock.now()
            while !Task.isCancelled, await !session.hasCollapsed(since: mark), clock.now().timeIntervalSince(began) < Self.seconds(Self.longestHold) {
                do { try await clock.sleep(for: ClickRouteRules.menuPoll) } catch { return }
            }
        }
    }

    /// An icon isn't put away under a menu that is open (it may be another icon's): the reveal waits for it to close.
    private func waitForNoMenu() async {
        let began = clock.now()
        while !Task.isCancelled, WindowRules.isMenuOpen(windows.onScreenWindows()), clock.now().timeIntervalSince(began) < Self.seconds(Self.longestHold) {
            do { try await clock.sleep(for: ClickRouteRules.menuPoll) } catch { return }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
