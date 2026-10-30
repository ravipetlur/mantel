import ApplicationServices
import CoreGraphics
import Foundation

/// The names of the Accessibility attributes the menu bar reader asks for (the values of the `kAX…Attribute` constants).
enum AXName {
    static let role = "AXRole"
    static let subrole = "AXSubrole"
    static let identifier = "AXIdentifier"
    static let main = "AXMain"
    static let focused = "AXFocused"
    static let description = "AXDescription"
    static let title = "AXTitle"
    static let position = "AXPosition"
    static let size = "AXSize"
    static let children = "AXChildren"
    static let windows = "AXWindows"
    static let extrasMenuBar = "AXExtrasMenuBar"
    static let menuBar = "AXMenuBar"
}

/// An element of some app's accessibility tree.
///
/// `AXUIElement` is a Core Foundation reference that Swift can't know to be safe to share between threads. It is: an
/// element is an immutable handle, and the calls on it are thread-safe (those about another process; this one's own are for the
/// main thread, see `OwnProcessAccess`). This wrapper is the one place that says so, and the rest of the platform layer passes
/// elements around as `AXElementRef`s.
public struct AXElementRef: @unchecked Sendable, Hashable {
    let element: AXUIElement

    public init(_ element: AXUIElement) {
        self.element = element
    }

    public static func == (lhs: AXElementRef, rhs: AXElementRef) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

/// What an attribute holds, for the kinds of value the menu bar reader uses.
public enum AXValueBox: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case point(CGPoint)
    case size(CGSize)
    /// One element or a list of them (an attribute that holds one element, such as the extras menu bar, comes as a list of one).
    case elements([AXElementRef])
    /// The attribute is there and holds something the reader has no use for.
    case none
}

public enum AXReadError: Error, Equatable, Sendable {
    /// The app didn't answer in time (`kAXErrorCannotComplete`, which is what a messaging timeout gives).
    case timeout
    /// Accessibility isn't granted to Mantel (`kAXErrorAPIDisabled`).
    case notTrusted
    /// The element has no such attribute, or no value for it.
    case noValue
    /// Any other `AXError`, by its raw value.
    case failure(Int32)
}

/// Reads and presses elements of the accessibility tree. The real one is `AXClient`; tests give the reader a fake tree.
public protocol AXReading: Sendable {
    func attribute(_ name: String, of element: AXElementRef) throws(AXReadError) -> AXValueBox
    func children(of element: AXElementRef) throws(AXReadError) -> [AXElementRef]
    /// The top-level element of the app with this process ID. It asks nothing of the app.
    func application(pid: pid_t) -> AXElementRef
    func press(_ element: AXElementRef) throws(AXReadError)
    /// The names of the attributes the element has, for the raw dump of a tree. A reader that can't say gives none.
    func attributeNames(of element: AXElementRef) throws(AXReadError) -> [String]
    /// The names of the actions the element offers (`AXPress`, `AXShowMenu`). A reader that can't say gives none.
    func actionNames(of element: AXElementRef) throws(AXReadError) -> [String]
    /// Performs one of the element's actions, by name. A reader that can't throws `noValue`.
    func perform(_ action: String, on element: AXElementRef) throws(AXReadError)
    /// `attribute(_:of:)`, waiting up to `wait` seconds for the app to answer instead of the reader's own wait. A reader that has no
    /// wait of its own (a fake tree) answers as `attribute(_:of:)` does.
    func attribute(_ name: String, of element: AXElementRef, wait: TimeInterval) throws(AXReadError) -> AXValueBox
    /// Quitting has begun: from now on, no call waits for an app any longer than it must. A reader that doesn't wait ignores it.
    func stopWaiting()
    /// The processes that are running now: a reader that remembers what apps have done forgets the others.
    func keep(onlyProcesses pids: Set<pid_t>)
    /// This process answers, however late a busy Mac makes it (MenuBarAgent, which the bar is read from): a reader that remembers what apps
    /// have done never takes it for one that doesn't.
    func expectAnswers(fromProcess pid: pid_t)
}

extension AXReading {
    public func attribute(_ name: String, of element: AXElementRef, wait: TimeInterval) throws(AXReadError) -> AXValueBox {
        try attribute(name, of: element)
    }
    public func stopWaiting() {}
    public func keep(onlyProcesses pids: Set<pid_t>) {}
    public func expectAnswers(fromProcess pid: pid_t) {}
    public func attributeNames(of element: AXElementRef) throws(AXReadError) -> [String] { [] }
    public func actionNames(of element: AXElementRef) throws(AXReadError) -> [String] { [] }
    public func perform(_ action: String, on element: AXElementRef) throws(AXReadError) { throw .noValue }
}

/// The real Accessibility API. Every call has a messaging timeout (`timeout`, in seconds, unless the caller gives another with `wait`),
/// so that one app that doesn't answer can't hold the whole read: it is `AXReadError.timeout`. Waiting longer for a busy Mac is
/// `PatientAX`'s: it asks again with longer waits.
///
/// It is for any thread. **Calls about Mantel's own process are made on the main thread** (`OwnProcessAccess`): AppKit answers them on
/// the calling thread, and wants the main one. They are answered in the process itself, so the messaging timeout doesn't apply to them.
public struct AXClient: AXReading {
    private let timeout: Float
    private let ownProcess: OwnProcessAccess

    public init(timeout: Float = 0.25, ownProcess: OwnProcessAccess = OwnProcessAccess()) {
        self.timeout = timeout
        self.ownProcess = ownProcess
    }

    public func attribute(_ name: String, of element: AXElementRef) throws(AXReadError) -> AXValueBox {
        try attribute(name, of: element, wait: TimeInterval(timeout))
    }

    public func attribute(_ name: String, of element: AXElementRef, wait: TimeInterval) throws(AXReadError) -> AXValueBox {
        let timeout = Float(wait)
        return try ownProcess.call(about: element) { () throws(AXReadError) -> AXValueBox in
            AXUIElementSetMessagingTimeout(element.element, timeout)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element.element, name as CFString, &value)
            guard result == .success else { throw Self.map(result) }
            guard let value else { return .none }
            return Self.box(value)
        }
    }

    public func children(of element: AXElementRef) throws(AXReadError) -> [AXElementRef] {
        do {
            if case .elements(let children) = try attribute(AXName.children, of: element) { return children }
            return []
        } catch AXReadError.noValue {
            return []
        }
    }

    public func application(pid: pid_t) -> AXElementRef {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, timeout)
        return AXElementRef(application)
    }

    public func press(_ element: AXElementRef) throws(AXReadError) {
        let timeout = timeout
        try ownProcess.call(about: element) { () throws(AXReadError) in
            AXUIElementSetMessagingTimeout(element.element, timeout)
            let result = AXUIElementPerformAction(element.element, kAXPressAction as CFString)
            guard result == .success else { throw Self.map(result) }
        }
    }

    public func attributeNames(of element: AXElementRef) throws(AXReadError) -> [String] {
        let timeout = timeout
        return try ownProcess.call(about: element) { () throws(AXReadError) -> [String] in
            AXUIElementSetMessagingTimeout(element.element, timeout)
            var names: CFArray?
            let result = AXUIElementCopyAttributeNames(element.element, &names)
            guard result == .success else { throw Self.map(result) }
            return (names as? [String]) ?? []
        }
    }

    public func actionNames(of element: AXElementRef) throws(AXReadError) -> [String] {
        let timeout = timeout
        return try ownProcess.call(about: element) { () throws(AXReadError) -> [String] in
            AXUIElementSetMessagingTimeout(element.element, timeout)
            var names: CFArray?
            let result = AXUIElementCopyActionNames(element.element, &names)
            guard result == .success else { throw Self.map(result) }
            return (names as? [String]) ?? []
        }
    }

    public func perform(_ action: String, on element: AXElementRef) throws(AXReadError) {
        let timeout = timeout
        try ownProcess.call(about: element) { () throws(AXReadError) in
            AXUIElementSetMessagingTimeout(element.element, timeout)
            let result = AXUIElementPerformAction(element.element, action as CFString)
            guard result == .success else { throw Self.map(result) }
        }
    }

    // MARK: Translating

    static func map(_ error: AXError) -> AXReadError {
        switch error {
        case .cannotComplete: .timeout
        case .apiDisabled: .notTrusted
        case .noValue, .attributeUnsupported: .noValue
        default: .failure(error.rawValue)
        }
    }

    static func box(_ value: CFTypeRef) -> AXValueBox {
        let type = CFGetTypeID(value)
        if type == CFStringGetTypeID() {
            return .string(value as? String ?? "")
        } else if type == CFBooleanGetTypeID() {
            return .bool(CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self)))
        } else if type == CFNumberGetTypeID() {
            return .number((value as? NSNumber)?.doubleValue ?? 0)
        } else if type == AXUIElementGetTypeID() {
            return .elements([AXElementRef(unsafeDowncast(value, to: AXUIElement.self))])
        } else if type == CFArrayGetTypeID() {
            let array = unsafeDowncast(value, to: CFArray.self)
            var elements: [AXElementRef] = []
            for index in 0..<CFArrayGetCount(array) {
                guard let item = CFArrayGetValueAtIndex(array, index) else { continue }
                let object = unsafeBitCast(item, to: CFTypeRef.self)
                if CFGetTypeID(object) == AXUIElementGetTypeID() {
                    elements.append(AXElementRef(unsafeDowncast(object, to: AXUIElement.self)))
                } else {
                    return .none
                }
            }
            return .elements(elements)
        } else if type == AXValueGetTypeID() {
            let axValue = unsafeDowncast(value, to: AXValue.self)
            switch AXValueGetType(axValue) {
            case .cgPoint:
                var point = CGPoint.zero
                return AXValueGetValue(axValue, .cgPoint, &point) ? .point(point) : .none
            case .cgSize:
                var size = CGSize.zero
                return AXValueGetValue(axValue, .cgSize, &size) ? .size(size) : .none
            default:
                return .none
            }
        }
        return .none
    }
}
