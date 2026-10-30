import CoreGraphics
import Foundation
import MKCore

/// One of MenuBarAgent's windows, as far as choosing between them needs it: where it is and where its slots are.
struct AgentWindowRead: Sendable, Equatable {
    /// The window's place among the agent's windows, in the order Accessibility lists them.
    let index: Int
    /// CoreGraphics global points; nil for a window whose frame couldn't be read, which can't be placed on a display.
    let frame: CGRect?
    /// Where each of its slots is (nil for a slot with no frame), in the order they are listed. Empty when the slots weren't read.
    let slotFrames: [CGRect?]
    /// How many of its slots have a name no other slot of it has (`AgentWindowReader.identifierCount`); nil when the names weren't read.
    var uniqueNameCount: Int? = nil
}

/// The windows that make up a display's menu bar.
struct ChosenWindow: Sendable, Equatable {
    let displayUUID: String
    /// The display's window that is used: its `AgentWindowRead.index`.
    let index: Int
    let frame: CGRect
    /// The `AgentWindowRead.index` of each of the display's windows: `index` first, then the others in the order Accessibility lists them.
    let candidates: [Int]
    /// The display has windows that show different slots. It is told only when the slots' frames were read.
    let isAmbiguous: Bool
}

/// Picks MenuBarAgent's windows for each display.
///
/// MenuBarAgent keeps a window per display for every Space, and the count changes as Spaces are visited. No attribute tells the active
/// Space's apart, and none is in the window list. Mostly they all show the same slots at the same places, and the first in
/// Accessibility's order will do. But the windows of the Spaces that aren't on screen can lag behind the bar (after a change of
/// displays they keep the slots they had), and can give every slot of an app its first item's name, while the window that is on screen
/// names each slot its own. So when the names were read, the window whose slots have the most names of their own (a name that repeats in
/// a window names none of its slots) is the one, and the first in Accessibility's order of those that have as many.
///
/// Only when the windows of one display don't agree (their slots differ in where they are and how wide) is the choice in doubt.
enum AgentWindowChooser {
    /// Slots and windows are the same place within this many points.
    private static let tolerance: CGFloat = 0.5

    /// - Parameter windows: every window MenuBarAgent has, in Accessibility's order.
    /// - Returns: a window for each display that has one, in the order of the layout's displays: the one with the most names of its own
    ///   when the names were read, else the first. A window that is on no display, or whose frame is unknown, is left out, and a display
    ///   without a window has no bar.
    static func choose(_ windows: [AgentWindowRead], layout: DisplayLayout) -> [ChosenWindow] {
        var byDisplay: [String: [(read: AgentWindowRead, frame: CGRect)]] = [:]
        for window in windows {
            guard let frame = window.frame, !frame.isEmpty,
                  let uuid = displayUUID(at: frame.origin, layout: layout) else { continue }
            byDisplay[uuid, default: []].append((window, frame))
        }

        var chosen: [ChosenWindow] = []
        for uuid in layout.displays.map(\.uuid) {
            guard let candidates = byDisplay[uuid], var best = candidates.first else { continue }
            for candidate in candidates.dropFirst() where (candidate.read.uniqueNameCount ?? -1) > (best.read.uniqueNameCount ?? -1) {
                best = candidate
            }
            let signature = Self.signature(of: best.read)
            let agree = candidates.allSatisfy { Self.sameSignature(Self.signature(of: $0.read), signature) }
            let others = candidates.map(\.read.index).filter { $0 != best.read.index }
            chosen.append(ChosenWindow(displayUUID: uuid, index: best.read.index, frame: best.frame, candidates: [best.read.index] + others,
                                       isAmbiguous: !agree))
        }
        return chosen
    }

    /// The display a window that starts at `origin` (CoreGraphics global points) is on: the first display, in the layout's order, whose
    /// area holds the point. Nil when no display does.
    static func displayUUID(at origin: CGPoint, layout: DisplayLayout) -> String? {
        layout.displays.first { layout.cgRect(fromAppKit: $0.frame).contains(origin) }?.uuid
    }

    /// Where a window's slots are, left to right: their x and width.
    private static func signature(of window: AgentWindowRead) -> [(x: CGFloat, width: CGFloat)] {
        window.slotFrames.compactMap { $0 }.map { (x: $0.minX, width: $0.width) }.sorted { ($0.x, $0.width) < ($1.x, $1.width) }
    }

    private static func sameSignature(_ a: [(x: CGFloat, width: CGFloat)], _ b: [(x: CGFloat, width: CGFloat)]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0.x - $1.x) <= tolerance && abs($0.width - $1.width) <= tolerance }
    }
}
