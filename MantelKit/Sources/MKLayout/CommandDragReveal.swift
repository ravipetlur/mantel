import Foundation

/// What a ⌘-drag of an icon in a menu bar asks of the reveal: to show everything while the icon is being moved (when the person turned
/// that on), and to put it away once the order that came of the drag has been followed. Pure: it takes what happened with its time and
/// says what to do.
///
/// - **Began:** with the option on, show everything.
/// - **Ended:** ask for the follow at once. The follow waits for macOS to settle the icon, then reads the bar (`MenuBarSession.commandDragEnded`),
///   so what the drag revealed stays on the bar until the last follow asked for is back (`.followed`), and then goes back to what it was
///   when the first drag began: collapsed, or the Hidden reveal the person had made with •. A reveal that was the person's own, not begun
///   by the drag, is left as it is.
/// - **No answer:** a follow that isn't back within `followTimeout` of the last one asked for collapses anyway. The follows still out then
///   come back before any later drag's (the follows run in order) and are no later drag's.
/// - **A mouse-up that was missed** (the app was deactivated mid-drag) is taken as one at `cap`: the follow is asked for, so the session's
///   drag doesn't stay open, and the reveal is kept for it like any other (it goes back on `.followed`, or at `followTimeout` later).
public struct CommandDragReveal: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        /// The drag began at this time; `showAllOn` is whether everything is to be shown for it, and `revealBefore` what the person had
        /// revealed then (what it goes back to afterwards).
        case began(at: Date, showAllOn: Bool, revealBefore: RevealLevel = .off)
        case ended(at: Date)
        /// What `.askFollow` asked for is done.
        case followed
        case tick(Date)
    }

    public enum Effect: Sendable, Equatable {
        case showAll
        /// Put the reveal back to this: what it was before the drag showed everything.
        case collapse(to: RevealLevel)
        /// Have the session read the order the drag left. `end` says how the drag ended: a mouse-up, or the cap (no mouse-up was seen).
        case askFollow(end: CommandDragLog.End)
    }

    /// The longest a drag lasts before its mouse-up is taken as missed.
    public static let cap: Duration = .seconds(10)
    /// How long it waits for `.followed` before collapsing anyway: the follower's own wait and two seconds for the read.
    public static let followTimeout: Duration = LayoutFollower.commandDragFollowDelay + .seconds(2)

    private enum Phase: Equatable {
        case idle
        case dragging(since: Date)
        case following(since: Date)
    }

    private var phase = Phase.idle
    /// What the reveal goes back to when the drag in progress (or being followed) is what showed everything; nil when it didn't.
    private var backTo: RevealLevel?
    /// How many follows were asked for and aren't back. The reveal stays until the last is: an earlier drag's follow coming back while a
    /// later one is still being waited for would collapse the bar before the later one's read.
    private var followsOwed = 0
    /// Follows still out when the timeout put the reveal back: the first to come back are theirs.
    private var lateFollows = 0

    public init() {}

    /// Whether the reveal a drag showed is still out (an earlier drag's, until its follow is back): a drag that begins now shows nothing.
    public var holdsDragReveal: Bool { backTo != nil }

    /// Whether a drag is in progress or being followed: when time has to be told to it.
    public var isActive: Bool { phase != .idle }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .began(let at, let showAllOn, let revealBefore):
            let shows = showAllOn && backTo == nil
            phase = .dragging(since: at)
            if shows {
                backTo = revealBefore
                return [.showAll]
            }
            return []
        case .ended(let at):
            guard case .dragging = phase else { return [] }
            phase = .following(since: at)
            followsOwed += 1
            return [.askFollow(end: .mouseUp)]
        case .followed:
            if lateFollows > 0 {
                lateFollows -= 1
                return []
            }
            guard followsOwed > 0 else { return [] }
            followsOwed -= 1
            // Another drag is going on, or another follow is still to come: what it reads needs the reveal.
            guard followsOwed == 0, case .following = phase else { return [] }
            return finish()
        case .tick(let now):
            switch phase {
            case .idle:
                return []
            case .dragging(let since):
                let held = Self.elapsed(since: since, now: now)
                guard held >= Self.seconds(Self.cap) else { return [] }
                phase = .following(since: now)
                followsOwed += 1
                return [.askFollow(end: .capReached(after: held))]
            case .following(let since):
                guard Self.elapsed(since: since, now: now) >= Self.seconds(Self.followTimeout) else { return [] }
                return finish()
            }
        }
    }

    private mutating func finish() -> [Effect] {
        let back = backTo
        phase = .idle
        backTo = nil
        // Zero when the last follow finished it; at the timeout, the follows that are still to come back.
        lateFollows += followsOwed
        followsOwed = 0
        return back.map { [.collapse(to: $0)] } ?? []
    }

    private static func elapsed(since start: Date, now: Date) -> TimeInterval {
        now.timeIntervalSince(start)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
