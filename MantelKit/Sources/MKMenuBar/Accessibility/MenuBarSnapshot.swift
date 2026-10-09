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
    /// The app didn't answer in time; it isn't asked again for a while.
    public let timedOut: Bool

    public init(pid: pid_t, bundleID: String?, name: String?, items: [ExtraItem], timedOut: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.items = items
        self.timedOut = timedOut
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

    public init(capturedAt: Date, layout: DisplayLayout, agentWindows: [AgentWindow], apps: [AppExtras],
                rawAgentTree: JSONValue?, problems: [String] = []) {
        self.capturedAt = capturedAt
        self.layout = layout
        self.agentWindows = agentWindows
        self.apps = apps
        self.rawAgentTree = rawAgentTree
        self.problems = problems
    }

    private enum CodingKeys: String, CodingKey {
        case capturedAt, layout, agentWindows, apps, rawAgentTree, problems
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        layout = try container.decode(DisplayLayout.self, forKey: .layout)
        agentWindows = try container.decode([AgentWindow].self, forKey: .agentWindows)
        apps = try container.decode([AppExtras].self, forKey: .apps)
        rawAgentTree = try container.decodeIfPresent(JSONValue.self, forKey: .rawAgentTree)
        problems = try container.decodeIfPresent([String].self, forKey: .problems) ?? []
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
