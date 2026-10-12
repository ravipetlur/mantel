import AppKit
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
            case .leftMouseDown: action = .clicked
            case .scrollWheel:
                guard event.momentumPhase.isEmpty else { return nil }
                action = .scrolled(deltaY: event.deltaY, invertedFromDevice: event.isDirectionInvertedFromDevice)
            default: return nil
            }
            location = NSEvent.mouseLocation
        }
    }

    private let classifier: PointerClassifier
    private let send: (RevealEvent) -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// Where the pointer was at the last event: what the next one is measured against.
    private var lastSpot: EmptySpace.Spot?

    /// - Parameter send: gives the reveal an event.
    init(classifier: PointerClassifier, send: @escaping (RevealEvent) -> Void) {
        self.classifier = classifier
        self.send = send
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
    }

    private func handle(_ seen: Seen) {
        let spot = classifier.spot(atAppKit: seen.location)
        // Whatever the pointer did, it is where it did it: a move into or out of empty space is told before a click or a scroll.
        for event in PointerReveal.events(for: seen.action, from: lastSpot, to: spot) { send(event) }
        lastSpot = spot
    }
}
