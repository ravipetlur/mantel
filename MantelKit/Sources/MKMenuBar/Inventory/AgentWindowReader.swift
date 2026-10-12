import CoreGraphics
import Foundation
import MKCore

/// What reading MenuBarAgent's windows gave.
struct AgentRead: Sendable {
    /// The window used for each display that has one, with its slots.
    var bars: [MatchBar] = []
    /// Some display's windows disagree about where their slots are. It is only told when the slots of every window were compared
    /// (`AgentReadPlan.thorough`).
    var isAmbiguous = false
    /// What a later, cheaper read starts from, for each display that was read for it (`WindowMemory`).
    var memory: [String: WindowMemory] = [:]
    /// Accessibility refused the read.
    var notTrusted = false
}

/// What a quick look at one display's bar found.
public struct BarLook: Sendable, Equatable {
    /// The display that was looked at.
    public let displayUUID: String
    /// How many of the bar's slots have a place on it: a frame that is on the bar. The « is not counted, and neither is a slot that has
    /// no frame (one macOS isn't drawing).
    public let drawnSlots: Int
    /// Every read of the window the look used was answered. False when one timed out: the look stopped there, and the count is what was
    /// seen till then, and may be short of what is there. (A timeout on a window that wasn't used doesn't count.)
    public let isComplete: Bool

    public init(displayUUID: String, drawnSlots: Int, isComplete: Bool = true) {
        self.displayUUID = displayUUID
        self.drawnSlots = drawnSlots
        self.isComplete = isComplete
    }
}

/// What is remembered of a display's windows between reads: what a later read compares a window with, and where it looks first.
struct WindowMemory: Sendable, Equatable {
    /// The most slots with an identifier that any of the display's windows was seen to have.
    var identifierCount: Int
    /// The window that was used last, by its place among all the agent's windows (`AgentWindowRead.index`).
    var best: Int
    /// The window that was read last for the sake of looking at another one (the place is the same as `best`'s); the next look is at
    /// the one after it.
    var looked: Int
}

/// How much of MenuBarAgent's windows is read.
///
/// MenuBarAgent keeps a window per display for every Space, and they all show the same slots, but some of them lack the identifiers
/// of the others, and a window that lacks them can gain them later. The window that is used is the one that has the most, and finding
/// it means reading windows that are otherwise never needed.
enum AgentReadPlan: Sendable {
    /// Every window of every display is read, and compared: where their slots are (are they the same?) and how many identifiers
    /// they have. The one with the most is used. It is for the moments the windows are likely to have changed: a change of displays, a
    /// refresh (the first read of a launch is one).
    case thorough
    /// Every window is read, and the one with the most identifiers is used, but they aren't compared. It is for an app launching or
    /// quitting, which is when a window is likely to gain or lose the names of its slots.
    case allWindows
    /// The window that was used last and one more of each display, in turn, so that every window is looked at now and then; and
    /// further ones only while none of those has as many identifiers as a window of the display was last seen to have. That is what
    /// keeps an ordinary scan to two windows per display, and finds a window that has gained names within a few scans. A display that
    /// has nothing remembered has all its windows read.
    case steady(memory: [String: WindowMemory])
}

/// Reads MenuBarAgent's windows through Accessibility, and an app's own menus.
///
/// The calls block, so everything here is `@concurrent`: the scanner awaits it and the actor stays free.
struct AgentWindowReader: Sendable {
    let ax: any AXReading

    /// The windows of a display that are read, in the order they are asked for.
    private struct Search {
        var order: [Int]
        /// How many of `order` are read whatever they have.
        var atLeast: Int
        /// Once `atLeast` are read, asking goes on until a window has this many identifiers.
        var wanted: Int
        /// Whether `order` has a window that is read only to look at it (the second).
        var looksAround: Bool
    }

    @concurrent
    func read(agent: RunningApp, layout: DisplayLayout, plan: AgentReadPlan) async -> AgentRead {
        let root = ax.application(pid: agent.pid)
        var elements: [AXElementRef] = []
        do {
            if case .elements(let listed) = try ax.attribute(AXName.windows, of: root) { elements = listed }
        } catch {
            if error == .notTrusted { return AgentRead(notTrusted: true) }
        }

        // What the windows say of where they are, and, when the plan wants to compare them, where their slots are.
        var slotsOfWindow: [Int: [AgentSlot]] = [:]
        var reads: [AgentWindowRead] = []
        for (index, element) in elements.enumerated() {
            var slotFrames: [CGRect?] = []
            if case .thorough = plan {
                let slots = self.slots(of: element)
                slotsOfWindow[index] = slots
                slotFrames = slots.map(\.frame)
            }
            reads.append(AgentWindowRead(index: index, frame: frame(of: element), slotFrames: slotFrames))
        }

        let chosen = AgentWindowChooser.choose(reads, layout: layout)
        var result = AgentRead()
        for window in chosen {
            let search = Self.search(of: window, plan: plan)

            var best: (index: Int, slots: [AgentSlot], count: Int)?
            var looked: Int?
            for (position, index) in search.order.enumerated() {
                let slots = slotsOfWindow[index] ?? self.slots(of: elements[index])
                let count = Self.identifierCount(slots)
                if best == nil || count > best?.count ?? 0 { best = (index, slots, count) }
                if search.looksAround, position == 1 { looked = index }
                if position + 1 >= search.atLeast, let best, best.count >= search.wanted { break }
            }
            guard let best else { continue }

            switch plan {
            case .thorough, .allWindows:
                result.memory[window.displayUUID] = WindowMemory(identifierCount: best.count, best: best.index, looked: best.index)
            case .steady(let known):
                // Without anything remembered the display was read whole, and the first look is the one after the best.
                result.memory[window.displayUUID] = WindowMemory(identifierCount: best.count, best: best.index,
                                                                 looked: looked ?? known[window.displayUUID]?.looked ?? best.index)
            }
            let frame = reads.first { $0.index == best.index }?.frame ?? window.frame
            result.bars.append(MatchBar(displayUUID: window.displayUUID, rect: frame, slots: best.slots))
            if window.isAmbiguous { result.isAmbiguous = true }
        }
        return result
    }

    /// Which of a display's windows are read for this plan, and when to stop.
    private static func search(of window: ChosenWindow, plan: AgentReadPlan) -> Search {
        let candidates = window.candidates
        let everyWindow = Search(order: candidates, atLeast: candidates.count, wanted: .max, looksAround: false)
        switch plan {
        case .thorough, .allWindows:
            return everyWindow
        case .steady(let memory):
            guard let known = memory[window.displayUUID] else { return everyWindow }
            // The window that was best is tried first, so that where it still is the best nothing is read to find it. Then the one
            // that is next in turn to be looked at, and then the others in order, which are only read while nothing has as many
            // identifiers as is known.
            let best = candidates.contains(known.best) ? known.best : window.index
            let others = candidates.filter { $0 != best }
            let next = others.first { $0 > known.looked } ?? others.first
            let order = [best] + (next.map { [$0] } ?? []) + others.filter { $0 != next }
            return Search(order: order, atLeast: min(2, order.count), wanted: known.identifierCount, looksAround: next != nil)
        }
    }

    /// How many of the slots have an identifier.
    static func identifierCount(_ slots: [AgentSlot]) -> Int {
        slots.filter { !($0.identifier ?? "").isEmpty }.count
    }

    /// A quick look at the main display's bar (the first display if none is main): how many of its slots have a place on it.
    ///
    /// It reads one window, the first of that display's (the chooser's rule), and in it each slot's role and frame, and nothing else: no
    /// names, no descriptions, no other window and no app. That is about three reads of Accessibility for each slot.
    ///
    /// **Timeouts.** A window is placed the way the chooser places it, by where it starts (one read), so a window that starts on another
    /// display is passed over without a second read, and nothing that happens to it counts against the look. A window that can't be placed
    /// (its position times out, or it has none) is passed over too. The first window that starts on the display is the one the look uses,
    /// and from there the first read that times out ends the look, where it is: the window isn't read on, and no other window is used in
    /// its place. What was counted till then stays, and `BarLook.isComplete` is false. A slot whose role times out isn't counted: it may
    /// be the «.
    ///
    /// - Returns: nil when there is no display, or Accessibility doesn't give MenuBarAgent's windows (it timed out, or was refused), or
    ///   none of them is on the display, or the used window's slots can't be listed (for any reason but a timeout). A look that went on
    ///   but had a read time out says so (`BarLook.isComplete`).
    @concurrent
    func look(agent: RunningApp, layout: DisplayLayout) async -> BarLook? {
        guard let display = layout.main ?? layout.displays.first else { return nil }
        let root = ax.application(pid: agent.pid)
        guard case .elements(let windows)? = try? ax.attribute(AXName.windows, of: root) else { return nil }

        // Only the reads of the window that is used are noted here: a read that timed out is a read that gave nothing.
        var timedOut = false
        func attribute(_ name: String, of element: AXElementRef) -> AXValueBox? {
            do {
                return try ax.attribute(name, of: element)
            } catch {
                if error == .timeout { timedOut = true }
                return nil
            }
        }
        func frame(of element: AXElementRef) -> CGRect? {
            guard case .point(let origin)? = attribute(AXName.position, of: element),
                  case .size(let size)? = attribute(AXName.size, of: element) else { return nil }
            return CGRect(origin: origin, size: size)
        }

        for window in windows {
            // The first window that starts on the display is the one the chooser takes (it is the first in Accessibility's order).
            guard case .point(let origin)? = try? ax.attribute(AXName.position, of: window),
                  AgentWindowChooser.displayUUID(at: origin, layout: layout) == display.uuid else { continue }
            var drawn = 0
            func stopped() -> BarLook { BarLook(displayUUID: display.uuid, drawnSlots: drawn, isComplete: false) }

            guard case .size(let size)? = attribute(AXName.size, of: window) else {
                if timedOut { return stopped() }
                continue
            }
            let bar = CGRect(origin: origin, size: size)
            // The chooser leaves out a window that has no area.
            guard !bar.isEmpty else { continue }

            let slots: [AXElementRef]
            do {
                slots = try ax.children(of: window)
            } catch {
                // A read that failed says nothing of the bar, and is not a bar with no slots (a hide would take it for one: everything
                // hidden). A timeout is an incomplete look; any other error, an element that has gone as MenuBarAgent restarts, is no look.
                return error == .timeout ? stopped() : nil
            }
            for slot in slots {
                let role = attribute(AXName.role, of: slot)
                if timedOut { return stopped() }
                if case .string(let name)? = role, name == OverflowDetector.chevronRole { continue }
                let slotFrame = frame(of: slot)
                if timedOut { return stopped() }
                if let slotFrame, slotFrame.width > 0, slotFrame.intersects(bar) { drawn += 1 }
            }
            return BarLook(displayUUID: display.uuid, drawnSlots: drawn)
        }
        return nil
    }

    /// The frames of an app's own menus (the children of its `AXMenuBar`), in CoreGraphics global points. Empty when the app has no
    /// menu bar or doesn't answer in time.
    @concurrent
    func menuFrames(pid: pid_t) async -> [CGRect] {
        let root = ax.application(pid: pid)
        guard case .elements(let bars)? = try? ax.attribute(AXName.menuBar, of: root), let bar = bars.first,
              let children = try? ax.children(of: bar) else { return [] }
        return children.compactMap(frame(of:)).filter { !$0.isEmpty }
    }

    // MARK: Slots

    private func slots(of window: AXElementRef) -> [AgentSlot] {
        ((try? ax.children(of: window)) ?? []).map { element in
            let role = string(AXName.role, of: element)
            return AgentSlot(frame: frame(of: element),
                             identifier: string(AXName.identifier, of: element) ?? firstIdentifier(below: element, depth: 3),
                             role: role, subrole: string(AXName.subrole, of: element), description: string(AXName.description, of: element),
                             ownerPID: nil, isOverflowChevron: role == OverflowDetector.chevronRole)
        }
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
}
