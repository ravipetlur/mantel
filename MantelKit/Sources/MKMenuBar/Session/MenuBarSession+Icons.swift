import CoreGraphics
import Foundation
import MKCore
import MKLayout

/// Where an item's slot is, as far as the plan and the last read can say: what the click path judges "drawn" by.
public enum IconSlotState: Sendable, Equatable {
    /// On a bar that is on screen, and not under the front app's menus or behind the notch.
    case drawn
    /// On a bar that is on screen, but out of the way: nothing clicks it there.
    case outOfTheWay
    /// On the bar of a display whose bar is hidden (a full-screen app has the display).
    case onHiddenBar
    /// The display isn't one the last read has a bar for.
    case unknown
}

/// Where the engines are with the plans (`MenuBarSession.applyProgress`).
struct ApplyProgress: Sendable, Equatable {
    /// A plan is being applied, or a switch of engine is under way.
    let underway: Bool
    /// How long ago the last one ended; nil when none has.
    let since: Duration?
}

/// Whether the bar is still, for a click that is about to be posted.
enum ClickFence: Sendable, Equatable {
    /// Nothing has changed the bar since the look, and nothing is changing it.
    case clear
    /// The bar was changed since the look: what it found may not be so now (look again).
    case barChanged
    /// The bar is being changed, or the click would fall into something else (a reset, a layout write that is pending or settling, a
    /// ⌘-drag, the quit, a change of displays a moment ago): nothing is posted.
    case blocked
}

// Icons asked for. Anything can ask for one icon to be shown wherever it is hidden (a click, a look at it) and get a ticket; the plan shows
// the icon's app, or the system item, until the ticket ends. The tickets, and the Shown apps that were concealed to make room for them, are
// kept in `MenuBarSession.swift` (a plan is made of them there).
extension MenuBarSession {
    /// Asks for these icons to be shown: their apps (and the system items among them) are visible whatever the sections and Focus Mode say.
    /// Returns once the plan is applied. The icons stay shown until `endIconReveal`, a reset or the quit.
    public func revealIcons(_ items: Set<ItemID>) async -> IconRevealTicket {
        let ticket = IconRevealTicket(id: nextIconTicket)
        nextIconTicket += 1
        guard !isQuitting else { return ticket }
        iconTickets[ticket.id] = items
        await rebuildAndApply()
        return ticket
    }

    /// Ends the ticket: its icons go back to where the plan puts them, and the apps that were concealed to make room for them are shown
    /// again. Returns once the plan is applied. A ticket that has ended already (a reset ends them all) is a no-op.
    public func endIconReveal(_ ticket: IconRevealTicket) async {
        guard iconTickets[ticket.id] != nil || iconRoomByTicket[ticket.id] != nil else { return }
        iconTickets[ticket.id] = nil
        iconRoomByTicket[ticket.id] = nil
        await rebuildAndApply()
    }

    /// Makes room for the ticket's apps: one round (the bar is read, and the Shown apps right-most first are concealed until what they
    /// drew is as wide as what the ticket's apps that have none need, as `SwapCalculator` counts). False when nothing more can be
    /// concealed, which is also when the ticket's apps have room already, when the ticket has ended and when the rounds are used up.
    /// The room ends with the ticket.
    public func makeRoom(for ticket: IconRevealTicket, round: Int) async -> Bool {
        guard !isQuitting, round >= 0, round < SwapCalculator.maximumRounds, let items = iconTickets[ticket.id] else { return false }
        let apps = appsOf(items)
        guard !apps.isEmpty, let taken = await requestRead(.reveal), iconTickets[ticket.id] != nil else { return false }
        let read = taken.inventory
        let overflowed = OverflowInputs.overflowedApps(in: read).intersection(apps)
        guard !overflowed.isEmpty else { return false }
        var blocked: Set<String> = swapConcealed
        for room in iconRoomByTicket.values { blocked.formUnion(room) }
        // The ticket's own apps are never concealed for it, and neither is another ticket's.
        for items in iconTickets.values { blocked.formUnion(appsOf(items)) }
        let concealed = appsToConceal(forRevealed: overflowed, in: read, alreadyConcealed: blocked).subtracting(blocked)
        guard !concealed.isEmpty else { return false }
        iconRoomByTicket[ticket.id, default: []].formUnion(concealed)
        Log.info("session", "made room for an icon by concealing \(concealed.count) Shown app(s) (round \(round + 1))")
        await rebuildAndApply()
        return true
    }

    /// Whether the ticket's apps are predicted to fit on the bars that are shown, with the room made so far: the widths they had when
    /// they were last on the bar against the free width, which the room made adds to (`RoomPrediction`). It reads nothing but the window
    /// list. True for an app whose width isn't known, and for a ticket that has ended.
    public func roomPredicted(for ticket: IconRevealTicket) async -> Bool {
        guard let items = iconTickets[ticket.id] else { return true }
        let off: Set<String> = if case .apps(let bundleIDs) = turnedOffList { Set(bundleIDs) } else { [] }
        let apps = appsOf(items).subtracting(off).filter { needsRoom($0) }
        guard !apps.isEmpty, !inventory.bars.isEmpty else { return true }
        return RoomPrediction.fits(Set(apps), inventory: inventory, widths: widths, menuFrames: frontAppMenuFrames(),
                                   shownBars: shownBars(of: inventory), concealedForRoom: iconRoomByTicket[ticket.id] ?? [])
    }

    /// Where the slot of a located item is: drawn, out of the way, or on a bar that isn't on screen. (The front app's menus are the ones
    /// read when the front app last changed.)
    public func slotState(of location: ItemLocation) -> IconSlotState {
        guard let bar = inventory.bars.first(where: { $0.displayUUID == location.displayUUID }) else { return .unknown }
        guard shownBars(of: inventory).contains(bar.displayUUID) else { return .onHiddenBar }
        return BarRegion.isOutOfTheWay(location.slotFrame, bar: bar, menuFrames: frontAppMenuFrames()) ? .outOfTheWay : .drawn
    }

    /// Whether the bar of the display (the bars all, when nil) is known and isn't on screen: a full-screen app has the display.
    public func isBarHidden(on display: String?) -> Bool {
        let bars = display.map { uuid in inventory.bars.filter { $0.displayUUID == uuid } } ?? inventory.bars
        guard !bars.isEmpty else { return false }
        let shown = shownBars(of: inventory)
        return bars.allSatisfy { !shown.contains($0.displayUUID) }
    }

    /// Whether the last read lists an item of the app: it is running, or was.
    public func hasItems(ofApp bundleID: String) -> Bool {
        !inventory.items(ofApp: bundleID).isEmpty
    }

    /// Whether the person turned the app off in System Settings › Menu Bar, as the last read of that list has it: macOS doesn't draw it.
    public func isTurnedOff(_ bundleID: String) -> Bool {
        if case .apps(let off) = turnedOffList { off.contains(bundleID) } else { false }
    }

    /// A mark of where the reveal machine is: pass it to `hasCollapsed(since:)` to ask whether the reveal has been put away since.
    public var revealMark: Int { revealGeneration }

    /// Whether the reveal has collapsed since the mark: it changed, and nothing is revealed now.
    public func hasCollapsed(since mark: Int) -> Bool {
        revealGeneration != mark && revealState == .collapsed
    }

    /// The menu bar of a display, as the last read has it.
    public func bar(on display: String) -> MenuBarGeometry? {
        inventory.bars.first { $0.displayUUID == display }
    }

    /// Whether the plan in force keeps the item off the bar: its app is concealed (or macOS has the app turned off), or it is a system item
    /// the plan takes away. An item of an app Mantel doesn't know of, or a system item with no number, is not.
    public func planConceals(_ item: ItemID) -> Bool {
        guard let plan = currentPlan else { return false }
        if case .system(let module) = item.key {
            guard let number = SystemItemTable.number(of: module) else { return false }
            return !plan.visibleSystemItems.contains(number)
        }
        return appsNotDrawn().contains(item.bundleID)
    }

    /// Whether the app has an icon that macOS doesn't tie to the app (`UnattachedIconTracker`): it never draws under the allowlist, so no
    /// room is made for it.
    public func isUnattached(_ bundleID: String) -> Bool {
        unattached.flagged.contains(bundleID)
    }

    /// How long after a change of displays nothing is posted: MenuBarAgent's other windows keep the old slots for a while (a read of a bar
    /// can settle on one), and no plan need follow a change of displays for the bar to move.
    static let displayChangeFence: TimeInterval = 3

    /// Whether a click may be posted now, given the count of `barChanges` when the click's own plans were in.
    func clickFence(since barChanges: Int) -> ClickFence {
        if isQuitting || resetting || layoutSettling || layoutIsPending || dragBefore != nil { return .blocked }
        if let changed = lastDisplayChangeAt, clock.now().timeIntervalSince(changed) < Self.displayChangeFence { return .blocked }
        return self.barChanges == barChanges ? .clear : .barChanged
    }

    /// The display whose bar the apps' frames are on (the active one), as the last read had it.
    var activeDisplay: String? { inventory.activeDisplay }

    /// The Shown apps concealed to make room for the ticket so far.
    func roomConcealed(for ticket: IconRevealTicket) -> Set<String> {
        iconRoomByTicket[ticket.id] ?? []
    }

    /// Shows again the apps that were concealed to make room for the ticket, and keeps the ticket's icons shown: the room is given back
    /// when the menu it was made for has closed. Returns once the plan is applied.
    func giveBackRoom(for ticket: IconRevealTicket) async {
        guard let room = iconRoomByTicket[ticket.id], !room.isEmpty else { return }
        iconRoomByTicket[ticket.id] = nil
        await rebuildAndApply()
    }

    /// Whether the item's app has an icon the last read says has no room (it is in the « menu or behind the notch, or has no place on the
    /// bar): what making room is for.
    func isOverflowed(_ item: ItemID) -> Bool {
        !item.isSystem && OverflowInputs.overflowedApps(in: inventory).contains(item.bundleID)
    }

    /// The process that owns an app's items, for the menu watch (a menu is that process's) and for whatever asks "is this app running".
    /// An app with one process is that one. Where several run under one bundle ID (a helper that has no items, say), it is the lowest of
    /// those the scans haven't found without items, once the last read's reach says the app answered; otherwise the lowest process. Nil when
    /// the app isn't running.
    public func extrasOwnerPID(ofApp bundleID: String) async -> pid_t? {
        let processes = runningApps().filter { $0.bundleID == bundleID }.sorted { $0.pid < $1.pid }
        guard processes.count > 1 else { return processes.first?.pid }
        let answered = inventory.reach.contains { $0.bundleID == bundleID && ($0.status == .fine || $0.status == .slow) }
        if answered {
            for process in processes where await !scanner.isKnownToHaveNoItems(process) { return process.pid }
        }
        return processes.first?.pid
    }

    /// Every ticket ends, and the room made for them is given back, without a plan being applied: for a reset (which makes its own) and the
    /// quit (which shows everything).
    func endAllIconReveals() {
        iconTickets = [:]
        iconRoomByTicket = [:]
    }

    /// The apps whose icons are among `items`, without Mantel's own.
    private func appsOf(_ items: Set<ItemID>) -> Set<String> {
        Set(items.filter { !$0.isSystem && $0.bundleID != ownBundleID }.map(\.bundleID))
    }

    /// An app needs room unless every icon of it is drawn on a bar in the last read.
    private func needsRoom(_ app: String) -> Bool {
        let items = inventory.items(ofApp: app)
        guard !items.isEmpty else { return true }
        return items.contains { item in item.frames.isEmpty || !item.overflowedOn.isEmpty }
    }
}
