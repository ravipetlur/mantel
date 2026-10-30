import AppKit
import MKCore
import MKLayout

/// Listens for the pointer on the menu bar, for the reveals that hover, click and scroll ask for, and says what it sees to the reveal
/// as events (`PointerReveal`). It is installed only while one of the three is on (`RevealSettings.usesPointer`).
///
/// - **Two kinds of monitor.** A global monitor sees the events other apps get, and a local one the events Mantel's own windows get
///   (a global monitor is never told of those). Neither can swallow an event: the local one hands it back as it came.
/// - **The pointer is read once, where the event happened,** and classified (`PointerClassifier`). What each of the three kinds of
///   event comes to is `PointerReveal`'s to say (a scroll is told with its direction as the event gives it, which `PointerReveal` turns
///   into the hand's own); the machine then decides whether the person turned that kind on.
/// - **Scrolling that carries on by itself** (a flick's momentum) is left out: only the hand's own scrolling is the person's.
/// - **Group hover.** The same pointer drives `GroupHover` for the groups that open on hover: where the pointer is (on such a group's
///   icon, on the open panel, or neither) is told to it with each event, and while it has a time to keep (a rest on an icon, a panel it
///   opened) the pointer is looked at again every `sampleInterval` and the time told, since no event comes while the pointer is on a
///   panel of Mantel's own that doesn't take mouse-moved events, or still on an icon.
final class EmptySpaceMonitor {
    private static let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .scrollWheel]

    /// What an event says, taken from it where it arrived so that nothing of the event itself is carried on.
    private nonisolated struct Seen: Sendable {
        let action: PointerReveal.Action
        /// AppKit global points.
        let location: CGPoint

        /// Nil for an event that isn't one of the three, or a scroll that carries on by itself.
        init?(_ event: NSEvent) {
            switch event.type {
            case .mouseMoved: action = .moved
            case .leftMouseDown:
                // A ⌘-mouse-down on the bar begins a drag of an icon, never a click for a reveal (the pointer may already be in a gap).
                guard !event.modifierFlags.contains(.command) else { return nil }
                action = .clicked
            case .scrollWheel:
                guard event.momentumPhase.isEmpty else { return nil }
                action = .scrolled(deltaY: event.deltaY, invertedFromDevice: event.isDirectionInvertedFromDevice)
            default: return nil
            }
            location = NSEvent.mouseLocation
        }
    }

    /// What the hover over a group's icon asks of the panels.
    struct GroupActions {
        /// Opens the group's panel, not made key. Says whether it opened one: not when it is open already, or the group has nothing to list.
        let open: (GroupID) -> Bool
        /// Closes the panel of this group, which the hover opened.
        let close: (GroupID) -> Void
        /// The open group panel's frame, in CoreGraphics global points; nil when none is open.
        let panelFrame: () -> CGRect?
    }

    /// How often the pointer is looked at while the group hover has a time to keep.
    private static let sampleInterval: Duration = .milliseconds(100)

    private let classifier: PointerClassifier
    private let send: (RevealEvent) -> Void
    private let groupActions: GroupActions
    /// The groups that open on hover; the monitor listens for them as well as for the reveals.
    private(set) var hoverGroups: Set<GroupID> = []
    private var hover = GroupHover()
    private var sampling: Task<Void, Never>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// Where the pointer was at the last event: what the next one is measured against.
    private var lastSpot: EmptySpace.Spot?

    /// - Parameters:
    ///   - send: gives the reveal an event.
    ///   - groupActions: what the pointer resting on a hover group's icon asks of the group's panel.
    init(classifier: PointerClassifier, send: @escaping (RevealEvent) -> Void, groupActions: GroupActions) {
        self.classifier = classifier
        self.send = send
        self.groupActions = groupActions
    }

    /// The groups that open on hover, as the layout has them now. With none the hover has nothing to do (and a panel it opened is
    /// left to close by the other ways).
    func setHoverGroups(_ groups: Set<GroupID>) {
        guard groups != hoverGroups else { return }
        hoverGroups = groups
        if groups.isEmpty { stopHover() }
    }

    /// A group's panel closed, whatever closed it: the hover opens it again only after the pointer has left the icon.
    func groupPanelClosed(_ group: GroupID) {
        hover.panelClosed(group)
    }

    /// The person clicked a group's icon: what the hover makes of it (`GroupHover.iconClicked`).
    func groupIconClicked(_ group: GroupID) -> GroupHover.IconClick {
        hover.iconClicked(group)
    }

    var isInstalled: Bool { globalMonitor != nil }

    /// Listens, or stops listening.
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
        lastSpot = nil
        stopHover()
    }

    private func stopHover() {
        sampling?.cancel()
        sampling = nil
        hover = GroupHover()
    }

    private func handle(_ seen: Seen) {
        let spot = classifier.spot(atAppKit: seen.location)
        // Whatever the pointer did, it is where it did it: a move into or out of empty space is told before a click or a scroll.
        for event in PointerReveal.events(for: seen.action, from: lastSpot, to: spot) { send(event) }
        lastSpot = spot
        if !hoverGroups.isEmpty { tellHover(spot: spot, appKitPoint: seen.location) }
    }

    // MARK: Group hover

    /// Tells the group hover where the pointer is, and what it asks for is done. A rest on an icon, or a panel the hover opened, makes it
    /// look again, on a task of its own.
    private func tellHover(spot: EmptySpace.Spot, appKitPoint: CGPoint, now: Date = Date()) {
        // A group icon that a read could only tell by its description has no group ID: it has no hover.
        let group = GroupHover.group(under: spot, among: hoverGroups)
        let onPanel = groupActions.panelFrame()?.contains(classifier.cgPoint(fromAppKit: appKitPoint)) ?? false
        _ = hover.handle(.pointer(onGroup: group, onPanel: onPanel, at: now))
        carryOut(hover.handle(.tick(now)))
        if hover.isActive, sampling == nil { startSampling() }
    }

    private func carryOut(_ effects: [GroupHover.Effect]) {
        for effect in effects {
            switch effect {
            case .open(let group):
                if !groupActions.open(group) { hover.declined(group) }
            case .close(let group): groupActions.close(group)
            }
        }
    }

    private func startSampling() {
        sampling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await SystemClock().sleep(for: Self.sampleInterval) } catch { return }
                guard let self, self.sampleHover() else { return }
            }
        }
    }

    /// Looks at the pointer once and tells the hover. False when the hover has nothing left to keep time for, which ends the sampling.
    private func sampleHover() -> Bool {
        guard !hoverGroups.isEmpty else {
            sampling = nil
            return false
        }
        let point = NSEvent.mouseLocation
        tellHover(spot: classifier.spot(atAppKit: point), appKitPoint: point)
        guard hover.isActive else {
            sampling = nil
            return false
        }
        return true
    }
}
