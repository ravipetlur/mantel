import CoreGraphics
import Foundation

/// How readily an app answered when its items were last read.
public enum ReachStatus: String, Codable, Sendable {
    /// It answered in under 100 ms and every read of its items came back.
    case fine
    /// It answered, but took 100 ms or more, or some reads of its items timed out.
    case slow
    /// It didn't answer in time: its list of items didn't come, or too many reads of its items didn't.
    case timedOut
    /// It timed out three times in a row and is left alone for a while.
    case skipped
}

/// What asking one app for its items was like, for Diagnostics.
public struct AppReach: Codable, Sendable, Equatable {
    public let bundleID: String
    public let name: String?
    public let status: ReachStatus
    /// How long the read took, in milliseconds; 0 for an app that wasn't asked.
    public let readMs: Double

    public init(bundleID: String, name: String?, status: ReachStatus, readMs: Double) {
        self.bundleID = bundleID
        self.name = name
        self.status = status
        self.readMs = readMs
    }
}

/// What kept the read of the menu bar from being whole.
public enum InventoryProblem: String, Codable, Sendable {
    case accessibilityNotGranted, agentNotRunning, agentHasNoWindows, ambiguousSpace

    /// What happened, in words for the person.
    public var message: String {
        switch self {
        case .accessibilityNotGranted: "Accessibility isn't granted to Mantel."
        case .agentNotRunning: "MenuBarAgent isn't running."
        case .agentHasNoWindows: "MenuBarAgent has no windows."
        case .ambiguousSpace: "Mantel couldn't tell which copy of the menu bar is current, so it used the one with the most names. If icons look wrong, choose Refresh Menu Bar."
        }
    }
}

/// The menu bar as Mantel read it at one moment: every item once, with where it is on each display.
public struct Inventory: Codable, Sendable, Equatable {
    public let capturedAt: Date
    /// One per display that has a menu bar.
    public let bars: [MenuBarGeometry]
    /// The items by their place on the main display, left to right; then the ones that are only on another display; then the
    /// concealed ones, grouped by app.
    ///
    /// **An app that is missing here isn't necessarily gone.** One that didn't answer (see `unansweredApps`) has no items in the
    /// list for as long as it doesn't, and so has an app whose items Mantel couldn't tell apart from the slots it didn't know (see
    /// `untiedSlots`).
    public let items: [MenuBarItem]
    /// Where the « is on each display that shows one (`DisplayInfo.uuid` to a CoreGraphics global frame).
    public let chevrons: [String: CGRect]
    public let reach: [AppReach]
    public let problems: [InventoryProblem]
    /// The apps that were asked for their items and didn't answer in time, or were left alone because they hadn't in a while (the
    /// apps whose reach is `timedOut` or `skipped`). Their items aren't in `items`, and that says nothing of whether they are
    /// there.
    public let unansweredApps: Set<String>
    /// The slots that have a frame on a display and that no item claimed, in CoreGraphics global points, left to right. The « is not
    /// among them, nor are the system's items, nor the slots in a bar's overflow whose items were found as a set (those items have
    /// the display in `MenuBarItem.overflowedOn`, though none of them has a slot there). The rest are drawn by something Mantel
    /// couldn't name: an app that didn't answer, or an item whose place couldn't be matched.
    public let untiedSlots: [String: [CGRect]]

    public init(capturedAt: Date, bars: [MenuBarGeometry], items: [MenuBarItem], chevrons: [String: CGRect], reach: [AppReach],
                problems: [InventoryProblem], unansweredApps: Set<String> = [], untiedSlots: [String: [CGRect]] = [:]) {
        self.capturedAt = capturedAt
        self.bars = bars
        self.items = items
        self.chevrons = chevrons
        self.reach = reach
        self.problems = problems
        self.unansweredApps = unansweredApps
        self.untiedSlots = untiedSlots
    }

    private enum CodingKeys: String, CodingKey {
        case capturedAt, bars, items, chevrons, reach, problems, unansweredApps, untiedSlots
    }

    /// An inventory saved before the last two were kept has neither.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        bars = try container.decode([MenuBarGeometry].self, forKey: .bars)
        items = try container.decode([MenuBarItem].self, forKey: .items)
        chevrons = try container.decode([String: CGRect].self, forKey: .chevrons)
        reach = try container.decode([AppReach].self, forKey: .reach)
        problems = try container.decode([InventoryProblem].self, forKey: .problems)
        unansweredApps = try container.decodeIfPresent(Set<String>.self, forKey: .unansweredApps) ?? []
        untiedSlots = try container.decodeIfPresent([String: [CGRect]].self, forKey: .untiedSlots) ?? [:]
    }

    /// Nothing read yet.
    public static let empty = Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: [], items: [], chevrons: [:], reach: [],
                                        problems: [])

    /// The items an app draws, in the order of `items`.
    public func items(ofApp bundleID: String) -> [MenuBarItem] {
        items.filter { $0.ownerBundleID == bundleID }
    }

    /// The bundle IDs of the apps that have items: not Mantel's, and not the system's. In the order their first item has in `items`.
    public var appsWithItems: [String] {
        var seen: Set<String> = []
        var apps: [String] = []
        for item in items where !item.isMantel && !item.id.isSystem && seen.insert(item.ownerBundleID).inserted {
            apps.append(item.ownerBundleID)
        }
        return apps
    }

    /// MenuBarAgent was there to be asked: it was running and had windows. (Accessibility not being granted is not the agent's
    /// failure.)
    public var agentAnswered: Bool {
        !problems.contains(.agentNotRunning) && !problems.contains(.agentHasNoWindows)
    }
}
