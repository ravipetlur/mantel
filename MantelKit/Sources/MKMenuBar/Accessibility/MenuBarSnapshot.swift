import CoreGraphics
import Foundation
import MKCommands
import MKCore

/// One item MenuBarAgent draws in a display's menu bar. MenuBarAgent draws each display's bar as one window, so all it
/// tells is these slots, from the Accessibility tree.
public struct AgentSlot: Codable, Sendable, Equatable {
    /// CoreGraphics global points; nil for a slot with no frame, which is one macOS has put in its « overflow.
    public let frame: CGRect?
    public let identifier: String?
    public let role: String?, subrole: String?, description: String?
    /// The app the slot belongs to, when it could be told (see `MenuBarReader`).
    public let ownerPID: pid_t?
    /// The « that opens the overflow. Told by its structure and never by its (localized) text.
    public let isOverflowChevron: Bool

    public init(frame: CGRect?, identifier: String?, role: String?, subrole: String?, description: String?,
                ownerPID: pid_t?, isOverflowChevron: Bool) {
        self.frame = frame
        self.identifier = identifier
        self.role = role
        self.subrole = subrole
        self.description = description
        self.ownerPID = ownerPID
        self.isOverflowChevron = isOverflowChevron
    }
}

/// MenuBarAgent's window for one display, and the slots in it.
public struct AgentWindow: Codable, Sendable, Equatable {
    public let frame: CGRect
    public let slots: [AgentSlot]

    public init(frame: CGRect, slots: [AgentSlot]) {
        self.frame = frame
        self.slots = slots
    }
}

/// What one of MenuBarAgent's windows says of itself, read from its own attributes (never from the slots in it): which of its
/// windows is the active Space's is not told by anything that is known yet, so what the windows differ in is recorded.
public struct AgentWindowDetail: Sendable, Equatable {
    public let frame: CGRect
    /// The values of `AXRole`, `AXSubrole`, `AXMain`, `AXFocused` and `AXIdentifier` where the window has them, and of every other
    /// attribute that holds a true or false.
    public let attributes: [String: JSONValue]
    public let slotCount: Int

    public init(frame: CGRect, attributes: [String: JSONValue], slotCount: Int) {
        self.frame = frame
        self.attributes = attributes
        self.slotCount = slotCount
    }
}

/// One status item of an app, as the app's own extras menu bar lists it.
public struct ExtraItem: Codable, Sendable, Equatable {
    public let index: Int
    public let frame: CGRect?
    public let identifier: String?
    public let title: String?
    public let description: String?

    public init(index: Int, frame: CGRect?, identifier: String?, title: String?, description: String?) {
        self.index = index
        self.frame = frame
        self.identifier = identifier
        self.title = title
        self.description = description
    }
}

/// What one running app has in the menu bar.
public struct AppExtras: Codable, Sendable, Equatable {
    public let pid: pid_t
    public let bundleID: String?
    public let name: String?
    public let items: [ExtraItem]
    /// The app didn't answer in time; it isn't asked again for a while. Set too when `AppExtrasReader.itemTimeoutsForAppTimeout`
    /// of the reads of its items timed out in one read.
    public let timedOut: Bool
    /// How many reads of an item's own attributes (its frame, identifier, title or description) timed out in this read. The item
    /// has no value for what was being read; the count says that this wasn't because the app has none.
    public let itemTimeouts: Int
    /// An item's name didn't come (the read of it timed out or failed) and nothing was remembered of it, not even that it has none: the
    /// item may have a name, so which ID it has isn't known from this read. Nothing is recorded of the app from a read like this
    /// (`WholeReads`).
    public let namesIncomplete: Bool
    /// The reading of the app's list stopped before its last child, for whatever reason (too many timeouts, a budget or a deadline that ran
    /// out): the app has items that `items` doesn't list. Nothing is recorded of the app from a read like this (`WholeReads`).
    public let listCut: Bool

    public init(pid: pid_t, bundleID: String?, name: String?, items: [ExtraItem], timedOut: Bool, itemTimeouts: Int = 0,
                namesIncomplete: Bool = false, listCut: Bool = false) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.items = items
        self.timedOut = timedOut
        self.itemTimeouts = itemTimeouts
        self.namesIncomplete = namesIncomplete
        self.listCut = listCut
    }

    private enum CodingKeys: String, CodingKey {
        case pid, bundleID, name, items, timedOut, itemTimeouts, namesIncomplete, listCut
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decode(pid_t.self, forKey: .pid)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        items = try container.decode([ExtraItem].self, forKey: .items)
        timedOut = try container.decode(Bool.self, forKey: .timedOut)
        // A snapshot saved before the count was kept has none.
        itemTimeouts = try container.decodeIfPresent(Int.self, forKey: .itemTimeouts) ?? 0
        namesIncomplete = try container.decodeIfPresent(Bool.self, forKey: .namesIncomplete) ?? false
        listCut = try container.decodeIfPresent(Bool.self, forKey: .listCut) ?? false
    }
}

/// The menu bar as Accessibility shows it at one moment.
public struct MenuBarSnapshot: Codable, Sendable, Equatable {
    public let capturedAt: Date
    public let layout: DisplayLayout
    public let agentWindows: [AgentWindow]
    public let apps: [AppExtras]
    /// The whole tree under MenuBarAgent, for the platform test (depth at most 6); nil in a normal read.
    public let rawAgentTree: JSONValue?
    /// What kept the read from being whole, in words: Accessibility isn't granted, MenuBarAgent isn't running.
    public let problems: [String]
    /// The frames of the front app's menus when the snapshot was taken, in CoreGraphics global points (a probe that is asked for the whole
    /// menu bar records them): without them a later replay can't tell which icons are under the menus (`BarRegion`). Empty when they
    /// weren't read. They are frames and nothing else: no name of the app or of a menu.
    public let frontMenuFrames: [CGRect]

    public init(capturedAt: Date, layout: DisplayLayout, agentWindows: [AgentWindow], apps: [AppExtras],
                rawAgentTree: JSONValue?, problems: [String] = [], frontMenuFrames: [CGRect] = []) {
        self.capturedAt = capturedAt
        self.layout = layout
        self.agentWindows = agentWindows
        self.apps = apps
        self.rawAgentTree = rawAgentTree
        self.problems = problems
        self.frontMenuFrames = frontMenuFrames
    }

    private enum CodingKeys: String, CodingKey {
        case capturedAt, layout, agentWindows, apps, rawAgentTree, problems, frontMenuFrames
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        layout = try container.decode(DisplayLayout.self, forKey: .layout)
        agentWindows = try container.decode([AgentWindow].self, forKey: .agentWindows)
        apps = try container.decode([AppExtras].self, forKey: .apps)
        rawAgentTree = try container.decodeIfPresent(JSONValue.self, forKey: .rawAgentTree)
        problems = try container.decodeIfPresent([String].self, forKey: .problems) ?? []
        frontMenuFrames = try container.decodeIfPresent([CGRect].self, forKey: .frontMenuFrames) ?? []
    }

    /// The snapshot with the front app's menus recorded.
    public func withFrontMenuFrames(_ frames: [CGRect]) -> MenuBarSnapshot {
        MenuBarSnapshot(capturedAt: capturedAt, layout: layout, agentWindows: agentWindows, apps: apps, rawAgentTree: rawAgentTree,
                        problems: problems, frontMenuFrames: frames)
    }
}

extension MenuBarSnapshot {
    /// Every slot of every window, in order.
    public var allSlots: [AgentSlot] {
        agentWindows.flatMap(\.slots)
    }

    /// The slots that have a frame: the ones macOS is drawing.
    public var framedSlots: [AgentSlot] {
        allSlots.filter { $0.frame != nil }
    }
}
