import ApplicationServices
import CoreGraphics
import Foundation
import MKCore

public enum ClickPostError: Error, Equatable, LocalizedError {
    /// Accessibility isn't granted to Mantel, so macOS would drop what it posts.
    case notTrusted
    /// macOS wouldn't make one of the events.
    case couldNotPost

    public var errorDescription: String? {
        switch self {
        case .notTrusted: "Mantel needs Device control and data access to click for you. Turn it on in Settings › Permissions."
        case .couldNotPost: "macOS wouldn't take the click. Try again."
        }
    }
}

/// Clicks as if the person had. The real one is `LiveClickPoster`; a test gives its own.
public protocol ClickPosting: Sendable {
    /// A down and an up of `kind` at `point` (CoreGraphics global points), 30 ms apart, marked with `ClickReplayTap.eventMark`; the pointer
    /// is then put back where it was.
    func click(_ kind: ClickKind, at point: CGPoint) throws(ClickPostError)
}

/// What posting a click comes to, as a value: the events in the order they are sent, and what is said of each. The live poster
/// sends what a plan says and decides nothing, so what is posted (which events, with which button and flags, in which order, marked how)
/// is tested without posting anything.
struct ClickPostPlan: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        /// A mouse event at `location`; `clickState` is the click count the event says it is (1: a single click).
        case mouse(type: CGEventType, button: CGMouseButton, location: CGPoint, flags: CGEventFlags, mark: Int64, clickState: Int64)
        /// Nothing is sent for this long.
        case wait(Duration)
        /// The pointer goes back to where it was: posting a click moves the real pointer.
        case putPointerBack(CGPoint)
    }

    /// How long the click is held down.
    static let pressDuration: Duration = .milliseconds(30)
    /// The click count of every event: a down and an up that make one click.
    static let singleClick: Int64 = 1

    let steps: [Step]

    /// A down and an up of `kind` at `point`. A right click is the right button; an option click is the left button with the Option key
    /// held (`maskAlternate`), and every click says its flags, so that a key the person happens to hold isn't part of it. The pointer is
    /// put back last, to `pointerWas`, when that is known.
    static func click(_ kind: ClickKind, at point: CGPoint, pointerWas: CGPoint?) -> ClickPostPlan {
        let button: CGMouseButton = kind == .right ? .right : .left
        let down: CGEventType = kind == .right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = kind == .right ? .rightMouseUp : .leftMouseUp
        let flags: CGEventFlags = kind == .option ? .maskAlternate : []
        let mark = ClickReplayTap.eventMark
        var steps: [Step] = [
            .mouse(type: down, button: button, location: point, flags: flags, mark: mark, clickState: singleClick),
            .wait(pressDuration),
            .mouse(type: up, button: button, location: point, flags: flags, mark: mark, clickState: singleClick),
        ]
        if let pointerWas { steps.append(.putPointerBack(pointerWas)) }
        return ClickPostPlan(steps: steps)
    }
}

/// The real poster: it sends what a `ClickPostPlan` says, through the HID event tap, so that the click lands as a person's does.
///
/// **Posting a click moves the real pointer.** The poster reads where it is first, and puts it back afterwards (`CGWarpMouseCursorPosition`,
/// then `CGAssociateMouseAndMouseCursorPosition(1)`, which a warp can leave off). Every event carries `ClickReplayTap.eventMark`, so
/// Mantel's own taps let them through. Without Accessibility macOS drops posted events, so none is posted (`notTrusted`).
///
/// The events are all made before the first is sent: a click that couldn't be made whole is not started, and there is no mouse-down left
/// without its up. A click holds the calling thread for the 30 ms between the down and the up, so it is called from a task, and not from the
/// main actor.
public struct LiveClickPoster: ClickPosting {
    public init() {}

    public func click(_ kind: ClickKind, at point: CGPoint) throws(ClickPostError) {
        guard AXIsProcessTrusted() else { throw .notTrusted }
        let pointer = CGEvent(source: nil)?.location
        try send(ClickPostPlan.click(kind, at: point, pointerWas: pointer))
    }

    private enum Prepared {
        case event(CGEvent)
        case wait(Duration)
        case putPointerBack(CGPoint)
    }

    private func send(_ plan: ClickPostPlan) throws(ClickPostError) {
        var prepared: [Prepared] = []
        for step in plan.steps {
            switch step {
            case .mouse(let type, let button, let location, let flags, let mark, let clickState):
                guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button) else {
                    throw .couldNotPost
                }
                event.flags = flags
                event.setIntegerValueField(.mouseEventClickState, value: clickState)
                event.setIntegerValueField(.eventSourceUserData, value: mark)
                prepared.append(.event(event))
            case .wait(let duration):
                prepared.append(.wait(duration))
            case .putPointerBack(let point):
                prepared.append(.putPointerBack(point))
            }
        }
        for step in prepared {
            switch step {
            case .event(let event):
                event.post(tap: .cghidEventTap)
            case .wait(let duration):
                Thread.sleep(forTimeInterval: Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
            case .putPointerBack(let point):
                CGWarpMouseCursorPosition(point)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }
    }
}
