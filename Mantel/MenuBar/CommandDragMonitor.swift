import AppKit
import MKCore
import MKLayout

/// Listens for ⌘-drags of icons in a menu bar and tells `CommandDragReveal`, which decides what each means. It is installed for as long as
/// the session runs: the session has to know a drag began whether or not everything is shown for it.
///
/// - **A drag begins** with a mouse-down, ⌘ held, on an icon (an app's or one of Mantel's own) in a bar that is on screen
///   (`PointerClassifier`). The session is told at once; with `showAllWhileCommandDragging` on, everything is shown too.
/// - **It ends** with the next mouse-up. The session reads the order the drag left (after its own wait), and a reveal the drag began is
///   put back to what it was once the last follow asked for is back.
/// - **A mouse-up that never comes** (the app was deactivated mid-drag) is taken as one when the drag has lasted `CommandDragReveal.cap`;
///   the machine is told the time every `tickInterval` while it has a drag to watch. The session is told it was the cap, so that the log
///   doesn't speak of a drop nobody saw.
final class CommandDragMonitor {
    private static let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp]
    private static let tickInterval: Duration = .milliseconds(250)

    /// What an event says, taken from it where it arrived.
    private nonisolated struct Seen: Sendable {
        let isDown: Bool
        let hasCommand: Bool
        /// Where the pointer was when the event happened, in CoreGraphics global points (the event's own place). Nil when the event has
        /// none (the pointer as it is now is used then): by the time the handler runs the pointer can be in a gap between two icons.
        let cgLocation: CGPoint?
        /// AppKit global points: the pointer now.
        let location: CGPoint

        init?(_ event: NSEvent) {
            switch event.type {
            case .leftMouseDown: isDown = true
            case .leftMouseUp: isDown = false
            default: return nil
            }
            hasCommand = event.modifierFlags.contains(.command)
            cgLocation = event.cgEvent?.location
            location = NSEvent.mouseLocation
        }
    }

    /// What a drag asks of the rest of the app.
    struct Actions {
        /// A drag began on an icon: the session keeps the order macOS shows, and logs whether everything is shown for it.
        let began: (CommandDragLog.ShowAll, Date) -> Void
        /// Shows everything on the menu bar itself, for a drag.
        let showAll: () -> Void
        /// The drag ended, at this time and in this way (a mouse-up, or the cap): the session reads the order the drag left, once its wait
        /// is over. Returns when it has.
        let follow: (Date, CommandDragLog.End) async -> Void
        /// Puts the reveal back to what it was when the drag began (collapsed, or the Hidden reveal the person had made).
        let collapse: (RevealLevel) -> Void
    }

    /// Whether everything is to be shown for a drag that begins now: the person turned it on, and nothing is showing that the drag would
    /// take over (everything, or Focus Mode), and no earlier drag's reveal is still out (the argument); if not, why not. Set once, by
    /// whoever owns the settings.
    var showsAll: (_ earlierDragShowing: Bool) -> CommandDragLog.ShowAll = { _ in .settingOff }
    /// What the person has revealed now: what the reveal goes back to after the drag. Set once, by whoever owns the reveal.
    var revealNow: () -> RevealLevel = { .off }

    private let classifier: PointerClassifier
    private let actions: Actions
    private var machine = CommandDragReveal()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var ticking: Task<Void, Never>?

    init(classifier: PointerClassifier, actions: Actions) {
        self.classifier = classifier
        self.actions = actions
    }

    var isInstalled: Bool { globalMonitor != nil }

    func setInstalled(_ on: Bool) {
        if on {
            install()
        } else {
            remove()
        }
    }

    private func install() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { [weak self] event in
            guard let seen = Seen(event) else { return }
            MainActor.assumeIsolated { self?.handle(seen) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.mask) { [weak self] event in
            if let seen = Seen(event) {
                MainActor.assumeIsolated { self?.handle(seen) }
            }
            return event
        }
    }

    private func remove() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        ticking?.cancel()
        ticking = nil
        machine = CommandDragReveal()
    }

    private func handle(_ seen: Seen) {
        if seen.isDown {
            guard seen.hasCommand, isOnIcon(seen) else { return }
            let verdict = showsAll(machine.holdsDragReveal)
            let seen = Date()
            actions.began(verdict, seen)
            carryOut(machine.handle(.began(at: seen, showAllOn: verdict == .shown, revealBefore: revealNow())), at: seen)
            startTicking()
        } else {
            let now = Date()
            carryOut(machine.handle(.ended(at: now)), at: now)
        }
    }

    /// Whether the pointer was on an icon of a bar that is on screen when the mouse went down: an app's, or one of Mantel's own.
    private func isOnIcon(_ seen: Seen) -> Bool {
        let spot = seen.cgLocation.map { classifier.spot(atCG: $0) } ?? classifier.spot(atAppKit: seen.location)
        return switch spot {
        case .item, .ownItem: true
        case .outsideBars, .hiddenBar, .appMenus, .notch, .empty: false
        }
    }

    /// `now` is when the effects were asked for: for a follow, when the drop was.
    private func carryOut(_ effects: [CommandDragReveal.Effect], at now: Date) {
        for effect in effects {
            switch effect {
            case .showAll:
                actions.showAll()
            case .collapse(let level):
                actions.collapse(level)
            case .askFollow(let end):
                Task { [weak self, actions] in
                    await actions.follow(now, end)
                    if let self { self.carryOut(self.machine.handle(.followed), at: Date()) }
                }
            }
        }
    }

    /// Tells the machine the time while it has a drag to watch: the cap on a drag whose mouse-up was missed, and the wait for the follow.
    private func startTicking() {
        guard ticking == nil else { return }
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                do { try await SystemClock().sleep(for: Self.tickInterval) } catch { return }
                guard let self else { return }
                let now = Date()
                self.carryOut(self.machine.handle(.tick(now)), at: now)
                if !self.machine.isActive {
                    self.ticking = nil
                    return
                }
            }
        }
    }
}
