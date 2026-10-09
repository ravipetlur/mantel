import CoreGraphics
import Foundation
import MKCommands
import MKCore
import Synchronization

/// Reads what is in the menu bar from the Accessibility tree: MenuBarAgent's windows and slots, and each running app's own
/// list of its status items.
///
/// - **MenuBarAgent** is found by its bundle ID among the running apps. Its Accessibility application has one window per
///   display (`AXWindows`), and the children of a window are the slots.
/// - **Each app with a bundle ID** has its items listed under `AXExtrasMenuBar`. An app that doesn't answer in time is
///   reported as `timedOut` with no items, and isn't asked again for 30 seconds, so that one hung app doesn't slow every read.
/// - **Who a slot belongs to** is told from its identifier (it holds the app's bundle ID) or, failing that, from an item
///   of an app that has the same frame.
/// - **The « chevron** is told structurally: a slot whose subrole is a menu extra's, with no identifier and no owner, that
///   has a description. Its text is localized, so it is never matched.
///
/// The read is blocking Accessibility calls, so it runs off the main actor, with at most eight apps asked at once.
public struct MenuBarReader: Sendable {
    public typealias RunningApp = (pid: pid_t, bundleID: String?, name: String?)

    public static let menuBarAgentBundleID = "com.apple.MenuBarAgent"
    /// How long an app that timed out is left alone.
    static let skipDuration: TimeInterval = 30
    /// How deep the raw dump of MenuBarAgent's tree goes, and how many elements it holds at most.
    static let rawTreeDepth = 6
    static let rawTreeNodeLimit = 2000
    /// How many apps are asked at the same time.
    static let concurrency = 8

    private let ax: any AXReading
    private let runningApps: @Sendable () -> [RunningApp]
    private let clock: any Clock
    private let skipped = SkippedApps()

    public init(ax: any AXReading, runningApps: @escaping @Sendable () -> [(pid: pid_t, bundleID: String?, name: String?)],
                clock: any Clock = SystemClock()) {
        self.ax = ax
        self.runningApps = runningApps
        self.clock = clock
    }

    // MARK: Snapshot

    @concurrent
    public func snapshot(layout: DisplayLayout, includeRawTree: Bool) async -> MenuBarSnapshot {
        let capturedAt = clock.now()
        let running = runningApps()
        let agent = running.first { $0.bundleID == Self.menuBarAgentBundleID }

        async let extras = readExtras(of: running.filter { $0.bundleID != nil && $0.bundleID != Self.menuBarAgentBundleID },
                                      now: capturedAt)
        async let agentRead = readAgent(agent, includeRawTree: includeRawTree)
        let (apps, extrasNotTrusted) = await extras
        let agentResult = await agentRead
        return Self.assemble(capturedAt: capturedAt, layout: layout, running: running, agentIsRunning: agent != nil,
                             agentResult: agentResult, apps: apps, notTrusted: extrasNotTrusted)
    }

    /// MenuBarAgent's windows and slots alone: no app is asked for its own list of items, and there is no raw tree. It is what
    /// a poll that watches for a change reads, because a change shows in the slots, and it costs one app's reads and not
    /// every app's. The snapshot has no `apps`, so a slot's owner is told by its identifier only, never by its frame.
    @concurrent
    public func agentSnapshot(layout: DisplayLayout) async -> MenuBarSnapshot {
        let capturedAt = clock.now()
        let running = runningApps()
        let agent = running.first { $0.bundleID == Self.menuBarAgentBundleID }
        let agentResult = await readAgent(agent, includeRawTree: false)
        return Self.assemble(capturedAt: capturedAt, layout: layout, running: running, agentIsRunning: agent != nil,
                             agentResult: agentResult, apps: [], notTrusted: false)
    }

    private static func assemble(capturedAt: Date, layout: DisplayLayout, running: [RunningApp], agentIsRunning: Bool,
                                 agentResult: AgentRead, apps: [AppExtras], notTrusted: Bool) -> MenuBarSnapshot {
        var problems: [String] = []
        if notTrusted || agentResult.notTrusted { problems.append("Accessibility isn't granted to Mantel.") }
        if !agentIsRunning { problems.append("MenuBarAgent isn't running.") }
        else if agentResult.windows.isEmpty, !agentResult.notTrusted { problems.append("MenuBarAgent has no windows.") }

        let windows = agentResult.windows.map { window in
            AgentWindow(frame: window.frame, slots: window.slots.map { slot(from: $0, apps: apps, running: running) })
        }
        return MenuBarSnapshot(capturedAt: capturedAt, layout: layout, agentWindows: windows, apps: apps,
                               rawAgentTree: agentResult.rawTree, problems: problems)
    }

    // MARK: Apps

    /// The apps that have status items (or timed out), in the order they came, and whether Accessibility was refused.
    private func readExtras(of apps: [RunningApp], now: Date) async -> (apps: [AppExtras], notTrusted: Bool) {
        let results = await Self.mapConcurrently(apps, limit: Self.concurrency) { app -> ExtrasResult in
            if skipped.isSkipped(app.pid, at: now) {
                return .timedOut(app)
            }
            let result = readExtras(of: app)
            if case .timedOut = result {
                skipped.skip(app.pid, until: now.addingTimeInterval(Self.skipDuration))
            }
            return result
        }
        var listed: [AppExtras] = []
        var notTrusted = false
        for result in results {
            switch result {
            case .items(let extras): listed.append(extras)
            case .timedOut(let app):
                listed.append(AppExtras(pid: app.pid, bundleID: app.bundleID, name: app.name, items: [], timedOut: true))
            case .notTrusted: notTrusted = true
            case .none: break
            }
        }
        return (listed, notTrusted)
    }

    private enum ExtrasResult: Sendable {
        case items(AppExtras)
        case timedOut(RunningApp)
        case notTrusted
        case none
    }

    private func readExtras(of app: RunningApp) -> ExtrasResult {
        let root = ax.application(pid: app.pid)
        do {
            guard case .elements(let bars) = try ax.attribute(AXName.extrasMenuBar, of: root), let bar = bars.first else {
                return .none
            }
            let children = try ax.children(of: bar)
            guard !children.isEmpty else { return .none }
            let items = children.enumerated().map { index, child in
                ExtraItem(index: index, frame: frame(of: child), identifier: string(AXName.identifier, of: child),
                          title: string(AXName.title, of: child), description: string(AXName.description, of: child))
            }
            return .items(AppExtras(pid: app.pid, bundleID: app.bundleID, name: app.name, items: items, timedOut: false))
        } catch {
            switch error {
            case .timeout: return .timedOut(app)
            case .notTrusted: return .notTrusted
            case .noValue, .failure: return .none
            }
        }
    }

    // MARK: MenuBarAgent

    private struct RawSlot: Sendable {
        var frame: CGRect?
        var identifier: String?
        var role: String?, subrole: String?, description: String?
    }

    private struct RawWindow: Sendable {
        var frame: CGRect
        var slots: [RawSlot]
    }

    private struct AgentRead: Sendable {
        var windows: [RawWindow] = []
        var rawTree: JSONValue?
        var notTrusted = false
    }

    private func readAgent(_ agent: RunningApp?, includeRawTree: Bool) async -> AgentRead {
        guard let agent else { return AgentRead() }
        var result = AgentRead()
        let root = ax.application(pid: agent.pid)
        do {
            if case .elements(let windows) = try ax.attribute(AXName.windows, of: root) {
                for window in windows {
                    let children = (try? ax.children(of: window)) ?? []
                    result.windows.append(RawWindow(frame: frame(of: window) ?? .zero, slots: children.map(rawSlot(from:))))
                }
            }
        } catch {
            if error == .notTrusted { result.notTrusted = true }
        }
        if includeRawTree, !result.notTrusted {
            var budget = Self.rawTreeNodeLimit
            result.rawTree = dump(root, depth: 0, budget: &budget)
        }
        return result
    }

    private func rawSlot(from element: AXElementRef) -> RawSlot {
        RawSlot(frame: frame(of: element),
                identifier: string(AXName.identifier, of: element) ?? firstIdentifier(below: element, depth: 3),
                role: string(AXName.role, of: element), subrole: string(AXName.subrole, of: element),
                description: string(AXName.description, of: element))
    }

    /// The identifier of the first descendant that has one: some slots carry theirs on a child.
    private func firstIdentifier(below element: AXElementRef, depth: Int) -> String? {
        guard depth > 0, let children = try? ax.children(of: element) else { return nil }
        for child in children {
            if let identifier = string(AXName.identifier, of: child) { return identifier }
            if let identifier = firstIdentifier(below: child, depth: depth - 1) { return identifier }
        }
        return nil
    }

    private static func slot(from raw: RawSlot, apps: [AppExtras], running: [RunningApp]) -> AgentSlot {
        let owner = ownerPID(of: raw, apps: apps, running: running)
        let hasIdentifier = !(raw.identifier ?? "").isEmpty
        let looksLikeAMenuExtra = raw.subrole?.contains("MenuExtra") ?? false
        let hasDescription = !(raw.description ?? "").isEmpty
        return AgentSlot(frame: raw.frame, identifier: raw.identifier, role: raw.role, subrole: raw.subrole,
                         description: raw.description, ownerPID: owner,
                         isOverflowChevron: looksLikeAMenuExtra && !hasIdentifier && hasDescription && owner == nil)
    }

    /// The app a slot belongs to: the one whose bundle ID its identifier contains (the longest such bundle ID, so that
    /// `com.example.app.helper` wins over `com.example.app`), or else the one that lists an item with the slot's frame.
    private static func ownerPID(of slot: RawSlot, apps: [AppExtras], running: [RunningApp]) -> pid_t? {
        if let identifier = slot.identifier, !identifier.isEmpty {
            let named = running.compactMap { app -> (pid_t, Int)? in
                guard let bundleID = app.bundleID, bundleID != menuBarAgentBundleID, identifier.contains(bundleID) else { return nil }
                return (app.pid, bundleID.count)
            }
            if let best = named.max(by: { $0.1 < $1.1 }) { return best.0 }
        }
        if let frame = slot.frame, frame.width > 0 {
            for app in apps {
                if app.items.contains(where: { item in item.frame.map { sameFrame($0, frame) } ?? false }) { return app.pid }
            }
        }
        return nil
    }

    /// Two frames are the same item's when they start and end within a point of each other.
    private static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.width - b.width) <= 1 && abs(a.minY - b.minY) <= 1
    }

    // MARK: Raw tree

    /// An element and what is below it, as JSON: the attributes the reader uses, the names of all the attributes, and the
    /// children, down to `rawTreeDepth`.
    private func dump(_ element: AXElementRef, depth: Int, budget: inout Int) -> JSONValue {
        budget -= 1
        var node: [String: JSONValue] = [:]
        for (key, name) in [("role", AXName.role), ("subrole", AXName.subrole), ("identifier", AXName.identifier),
                            ("description", AXName.description), ("title", AXName.title)] {
            if let value = string(name, of: element) { node[key] = .string(value) }
        }
        if let frame = frame(of: element) {
            node["frame"] = .object(["x": .number(frame.minX), "y": .number(frame.minY),
                                     "width": .number(frame.width), "height": .number(frame.height)])
        }
        if let names = try? ax.attributeNames(of: element) {
            node["attributes"] = .array(names.map(JSONValue.string))
        }
        let children = (try? ax.children(of: element)) ?? []
        if depth >= Self.rawTreeDepth {
            if !children.isEmpty { node["childCount"] = .number(Double(children.count)) }
        } else {
            var dumped: [JSONValue] = []
            for child in children {
                guard budget > 0 else {
                    node["truncated"] = .bool(true)
                    break
                }
                dumped.append(dump(child, depth: depth + 1, budget: &budget))
            }
            node["children"] = .array(dumped)
        }
        return .object(node)
    }

    // MARK: Attributes

    private func string(_ name: String, of element: AXElementRef) -> String? {
        guard case .string(let value)? = try? ax.attribute(name, of: element), !value.isEmpty else { return nil }
        return value
    }

    /// The element's frame from its position and size; nil when either is missing.
    private func frame(of element: AXElementRef) -> CGRect? {
        guard case .point(let origin)? = try? ax.attribute(AXName.position, of: element),
              case .size(let size)? = try? ax.attribute(AXName.size, of: element) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: Running things at once

    /// `transform` for each item, at most `limit` at a time, results in the order of the items. The work blocks (it is
    /// Accessibility calls), so the limit keeps it from taking every thread the system has.
    private static func mapConcurrently<Item: Sendable, Result: Sendable>(
        _ items: [Item], limit: Int, _ transform: @escaping @Sendable (Item) -> Result
    ) async -> [Result] {
        await withTaskGroup(of: (Int, Result).self) { group in
            var results: [Result?] = Array(repeating: nil, count: items.count)
            var next = 0
            func addNext() {
                guard next < items.count else { return }
                let index = next
                let item = items[index]
                next += 1
                group.addTask { (index, transform(item)) }
            }
            for _ in 0..<min(limit, items.count) { addNext() }
            while let (index, result) = await group.next() {
                results[index] = result
                addNext()
            }
            return results.compactMap { $0 }
        }
    }
}

/// The apps that timed out and until when they are left alone; shared by every copy of a reader.
private final class SkippedApps: Sendable {
    private let until = Mutex<[pid_t: Date]>([:])

    func isSkipped(_ pid: pid_t, at now: Date) -> Bool {
        until.withLock { map in
            guard let end = map[pid] else { return false }
            if now < end { return true }
            map[pid] = nil
            return false
        }
    }

    func skip(_ pid: pid_t, until end: Date) {
        until.withLock { $0[pid] = end }
    }
}
