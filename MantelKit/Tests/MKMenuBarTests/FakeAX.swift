import ApplicationServices
import CoreGraphics
import Foundation
import Synchronization

@testable import MKMenuBar

/// A fake accessibility tree. An element is an id; its `AXElementRef` is an application element for a made-up process ID
/// (1 000 000 + id), which is only an object in memory: making one, and asking it its process ID, sends nothing anywhere.
final class FakeAX: AXReading {
    struct Node: Sendable {
        var attributes: [String: AXValueBox] = [:]
        var children: [Int] = []
        /// Every read of an attribute of this node fails with this.
        var attributeError: AXReadError?
        var pressError: AXReadError?
        /// The actions the element offers, by name (`AXShowMenu`); `AXPress` is pressed without being listed.
        var actions: [String] = []
        /// Every action performed on this node fails with this.
        var performError: AXReadError?
        /// Reading the list of actions the element offers fails with this.
        var actionsError: AXReadError?
    }

    private struct State {
        var nodes: [Int: Node] = [:]
        var applicationRoots: [pid_t: Int] = [:]
        var attributeReads: [Int: Int] = [:]
        var presses: [Int] = []
        var performed: [Performed] = []
        var nextID = 1
        var override: Override?
        /// The app (by process ID) whose tree each node is in, for the nodes added through `addApp`, `addAgentWindow` and `addSlot`.
        var owners: [Int: pid_t] = [:]
    }

    /// An action that was performed on a node.
    struct Performed: Equatable, Sendable {
        let id: Int
        let action: String
    }

    /// Decides an attribute read in place of the tree: nil leaves it to the tree. For a test where what is on screen depends
    /// on something that changes while the probe runs.
    typealias Override = @Sendable (_ id: Int, _ name: String) -> Result<AXValueBox, AXReadError>?

    private let state = Mutex(State())
    /// Whether each read (each `application(pid:)`) gives new elements for the same nodes: equal in what they are, not in which element
    /// they are; and the number of the read. Apart from `state`, which `ref` is made in the middle of.
    private let handles = Mutex((fresh: false, generation: 0))
    private static let pidBase = 1_000_000
    private static let generationStride = 100_000

    // MARK: AXReading

    func attribute(_ name: String, of element: AXElementRef) throws(AXReadError) -> AXValueBox {
        let id = id(of: element)
        let override = state.withLock { $0.override }
        if let decided = override?(id, name) {
            state.withLock { $0.attributeReads[id, default: 0] += 1 }
            return try decided.get()
        }
        let outcome = state.withLock { state -> Result<AXValueBox, AXReadError> in
            state.attributeReads[id, default: 0] += 1
            guard let node = state.nodes[id] else { return .failure(.noValue) }
            if let error = node.attributeError { return .failure(error) }
            if name == AXName.children { return .success(.elements(node.children.map(ref))) }
            guard let value = node.attributes[name] else { return .failure(.noValue) }
            return .success(value)
        }
        return try outcome.get()
    }

    func children(of element: AXElementRef) throws(AXReadError) -> [AXElementRef] {
        if case .elements(let children) = try attribute(AXName.children, of: element) { return children }
        return []
    }

    func application(pid: pid_t) -> AXElementRef {
        let id = state.withLock { state -> Int in
            handles.withLock { if $0.fresh { $0.generation += 1 } }
            if let id = state.applicationRoots[pid] { return id }
            let id = state.nextID
            state.nextID += 1
            state.nodes[id] = Node()
            state.applicationRoots[pid] = id
            return id
        }
        return ref(id)
    }

    func press(_ element: AXElementRef) throws(AXReadError) {
        let id = id(of: element)
        let error = state.withLock { state -> AXReadError? in
            state.presses.append(id)
            return state.nodes[id]?.pressError
        }
        if let error { throw error }
    }

    func attributeNames(of element: AXElementRef) throws(AXReadError) -> [String] {
        let id = id(of: element)
        return state.withLock { state in
            guard let node = state.nodes[id] else { return [] }
            return (Array(node.attributes.keys) + [AXName.children]).sorted()
        }
    }

    func actionNames(of element: AXElementRef) throws(AXReadError) -> [String] {
        let id = id(of: element)
        let outcome = state.withLock { state -> (error: AXReadError?, actions: [String]) in (state.nodes[id]?.actionsError, state.nodes[id]?.actions ?? []) }
        if let error = outcome.error { throw error }
        return outcome.actions
    }

    func perform(_ action: String, on element: AXElementRef) throws(AXReadError) {
        let id = id(of: element)
        let error = state.withLock { state -> AXReadError? in
            state.performed.append(Performed(id: id, action: action))
            return state.nodes[id]?.performError
        }
        if let error { throw error }
    }

    /// The process whose tree the element is in, when it was added through `addApp`, `addAgentWindow` or `addSlot`.
    func ownerPID(of element: AXElementRef) -> pid_t? {
        let id = id(of: element)
        return state.withLock { $0.owners[id] }
    }

    private func setOwner(_ pid: pid_t, of ids: [Int]) {
        state.withLock { state in for id in ids { state.owners[id] = pid } }
    }

    // MARK: Building a tree

    /// The element for a node: the same one each time, unless `giveNewElementsAtEachRead` is on, when it is the one of the read's own.
    func ref(_ id: Int) -> AXElementRef {
        let generation = handles.withLock { $0.fresh ? $0.generation : 0 }
        return AXElementRef(AXUIElementCreateApplication(pid_t(Self.pidBase + id + generation * Self.generationStride)))
    }

    func id(of element: AXElementRef) -> Int {
        var pid: pid_t = 0
        AXUIElementGetPid(element.element, &pid)
        return (Int(pid) - Self.pidBase) % Self.generationStride
    }

    /// An app that makes new elements for its items at each read (what it lists at each read is not the element it listed before).
    func giveNewElementsAtEachRead(_ on: Bool = true) {
        handles.withLock { $0.fresh = on }
    }

    @discardableResult
    func addNode(attributes: [String: AXValueBox] = [:], under parent: Int? = nil) -> Int {
        state.withLock { state in
            let id = state.nextID
            state.nextID += 1
            state.nodes[id] = Node(attributes: attributes)
            if let parent { state.nodes[parent]?.children.append(id) }
            return id
        }
    }

    /// The root of the app with this process ID, made if it isn't there yet.
    @discardableResult
    func root(ofApp pid: pid_t) -> Int {
        id(of: application(pid: pid))
    }

    func setAttribute(_ name: String, _ value: AXValueBox, on id: Int) {
        state.withLock { $0.nodes[id]?.attributes[name] = value }
    }

    /// The element goes from its parent's list: the app has dropped the item.
    func removeNode(_ id: Int) {
        state.withLock { state in for key in state.nodes.keys { state.nodes[key]?.children.removeAll { $0 == id } } }
    }

    /// The two elements trade places in their parent's list: the app lists its items in another order.
    func swapPlaces(of first: Int, and second: Int) {
        state.withLock { state in
            for key in state.nodes.keys {
                guard let a = state.nodes[key]?.children.firstIndex(of: first), let b = state.nodes[key]?.children.firstIndex(of: second) else { continue }
                state.nodes[key]?.children.swapAt(a, b)
            }
        }
    }

    func setOverride(_ override: Override?) {
        state.withLock { $0.override = override }
    }

    func failReads(on id: Int, with error: AXReadError?) {
        state.withLock { $0.nodes[id]?.attributeError = error }
    }

    func failPress(on id: Int, with error: AXReadError?) {
        state.withLock { $0.nodes[id]?.pressError = error }
    }

    func setActions(_ actions: [String], on id: Int) {
        state.withLock { $0.nodes[id]?.actions = actions }
    }

    func failActions(on id: Int, with error: AXReadError?) {
        state.withLock { $0.nodes[id]?.actionsError = error }
    }

    func failPerform(on id: Int, with error: AXReadError?) {
        state.withLock { $0.nodes[id]?.performError = error }
    }

    /// The actions that were performed (not presses), in order.
    var performedActions: [Performed] {
        state.withLock { $0.performed }
    }

    func attributeReads(on id: Int) -> Int {
        state.withLock { $0.attributeReads[id] ?? 0 }
    }

    var pressed: [Int] {
        state.withLock { $0.presses }
    }

    /// One window of MenuBarAgent's, with its frame; returns its id.
    @discardableResult
    func addAgentWindow(agent pid: pid_t, frame: CGRect) -> Int {
        let agentRoot = root(ofApp: pid)
        defer { setOwner(pid, of: [agentRoot]) }
        let window = addNode(attributes: Self.frameAttributes(frame).merging([AXName.role: .string("AXWindow")]) { $1 }, under: agentRoot)
        let existing: [AXElementRef]
        if case .elements(let list)? = state.withLock({ $0.nodes[agentRoot]?.attributes[AXName.windows] }) { existing = list } else { existing = [] }
        setAttribute(AXName.windows, .elements(existing + [ref(window)]), on: agentRoot)
        setOwner(pid, of: [window])
        return window
    }

    /// A slot in a window. With `childIdentifier`, the identifier is on a child of the slot, not on the slot.
    @discardableResult
    func addSlot(in window: Int, identifier: String? = nil, childIdentifier: String? = nil, role: String = "AXGroup",
                 subrole: String? = "AXHostingView", description: String? = nil, frame: CGRect? = nil) -> Int {
        var attributes: [String: AXValueBox] = [AXName.role: .string(role)]
        if let subrole { attributes[AXName.subrole] = .string(subrole) }
        if let identifier { attributes[AXName.identifier] = .string(identifier) }
        if let description { attributes[AXName.description] = .string(description) }
        if let frame { attributes.merge(Self.frameAttributes(frame)) { $1 } }
        let slot = addNode(attributes: attributes, under: window)
        var below = [slot]
        if let childIdentifier {
            below.append(addNode(attributes: [AXName.role: .string("AXGroup"), AXName.identifier: .string(childIdentifier)], under: slot))
        }
        if let owner = state.withLock({ $0.owners[window] }) { setOwner(owner, of: below) }
        return slot
    }

    struct Extra {
        var title: String? = nil
        var identifier: String? = nil
        var description: String? = nil
        var frame: CGRect? = nil
    }

    /// An app with these status items in its extras menu bar. The elements of the items are given back.
    @discardableResult
    func addApp(pid: pid_t, extras: [Extra]) -> [Int] {
        let root = root(ofApp: pid)
        guard !extras.isEmpty else { return [] }
        let bar = addNode(attributes: [AXName.role: .string("AXMenuBar")])
        var items: [Int] = []
        for extra in extras {
            var attributes: [String: AXValueBox] = [AXName.role: .string("AXMenuBarItem")]
            if let title = extra.title { attributes[AXName.title] = .string(title) }
            if let identifier = extra.identifier { attributes[AXName.identifier] = .string(identifier) }
            if let description = extra.description { attributes[AXName.description] = .string(description) }
            if let frame = extra.frame { attributes.merge(Self.frameAttributes(frame)) { $1 } }
            items.append(addNode(attributes: attributes, under: bar))
        }
        setAttribute(AXName.extrasMenuBar, .elements([ref(bar)]), on: root)
        setOwner(pid, of: [root, bar] + items)
        return items
    }

    static func frameAttributes(_ frame: CGRect) -> [String: AXValueBox] {
        [AXName.position: .point(frame.origin), AXName.size: .size(frame.size)]
    }
}
