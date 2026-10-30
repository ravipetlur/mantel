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
    /// It said no to Accessibility while Mantel has the grant: some apps answer every read with "API disabled", whoever asks. It is
    /// asked again after the pause an app with no items gets.
    case refused
}

extension ReachStatus {
    /// Whether the app gave its whole list: `fine`, or `slow` (late, or some reads of an item's attributes timed out, but the list came
    /// to its end). Any other status, a new one included, is not a full answer.
    public var isFullAnswer: Bool {
        switch self {
        case .fine, .slow: true
        case .timedOut, .skipped, .refused: false
        }
    }
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
        case .accessibilityNotGranted: "Device control and data access isn't granted to Mantel."
        case .agentNotRunning: "MenuBarAgent isn't running."
        case .agentHasNoWindows: "MenuBarAgent has no windows."
        case .ambiguousSpace: "Mantel couldn't tell which copy of the menu bar is current, so it used the one with the most names. If icons look wrong, choose Refresh Menu Bar."
        }
    }
}

/// One slot of a bar as MenuBarAgent draws it: where it is, and the name it carries.
public struct BarSlot: Codable, Sendable, Equatable {
    /// CoreGraphics global points.
    public let frame: CGRect
    /// The name the slot carries, when it names an item and no other slot of the bar has it; nil for one with none.
    public let name: String?

    public init(frame: CGRect, name: String?) {
        self.frame = frame
        self.name = name
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
    /// The apps that were asked for their items and didn't answer in time, or were left alone because they hadn't in a while, or that
    /// refuse Accessibility (the apps whose reach is `timedOut`, `skipped` or `refused`). Their items aren't in `items`, and that says
    /// nothing of whether they are there.
    public let unansweredApps: Set<String>
    /// The slots that have a frame on a display and that no item claimed, in CoreGraphics global points, left to right. The « is not
    /// among them, nor are the system's items, nor the slots in a bar's overflow whose items were found as a set (those items have
    /// the display in `MenuBarItem.overflowedOn`, though none of them has a slot there). The rest are drawn by something Mantel
    /// couldn't name: an app that didn't answer, or an item whose place couldn't be matched.
    public let untiedSlots: [String: [CGRect]]
    /// The display whose bar the apps' own reported frames are on: macOS reports them on the bar of the display that is active (where the
    /// key window is), and the other displays draw their icons translucent. Nil when no bar has more of them than every other, which
    /// is when it can't be told.
    public let activeDisplay: String?
    /// Every slot drawn on each display's bar at the read, left to right (the « is not one): the whole list the items' frames and
    /// `untiedSlots` are taken from, with the names the slots carry. What a later look at the bar is compared with, to tell that the bar
    /// is still the one the read was of. Empty for a display the read has no bar for.
    public let barSlots: [String: [BarSlot]]

    /// The apps whose frame was nearly as close to a slot as another app's that won it (within 2 pt). Which of the two the slot is
    /// is a near tie, and what the read says of either app's place is not to be believed (`InventoryMatcher.claimSlots`).
    public let contestedApps: Set<String>

    /// The apps that answered, with an item whose name didn't come and was remembered by nothing (`AppExtras.namesIncomplete`), or whose list
    /// was read only part of the way (`AppExtras.listCut`): which icons they have isn't known from this read, and nothing is recorded
    /// of them.
    public let incompleteApps: Set<String>

    /// The processes that listed each app's items in this read, by bundle ID. A change from one read to the next is an app that was
    /// started again (or one that runs as several processes).
    public let appProcesses: [String: Set<Int32>]

    /// Some read of MenuBarAgent's windows timed out, or was cut by the read's budget or deadline, so a slot may lack its frame or name or
    /// a window may have been passed over: the bars are what was seen, and may be short of what is there. The order of the icons isn't
    /// followed from such a read.
    public let agentReadCut: Bool

    /// The bundle IDs of the apps that were running when the read was taken: every running app, whether or not it has an icon on the bar.
    /// An app that is missing from `items` isn't necessarily not running, so whether an app runs is judged from this and from nothing
    /// else. Nil when the read doesn't say (it couldn't be taken, or it was saved before this was kept): nothing is then said to be not
    /// running. Not part of what a read says of the menu bar (`==`).
    public let runningApps: Set<String>?

    public init(capturedAt: Date, bars: [MenuBarGeometry], items: [MenuBarItem], chevrons: [String: CGRect], reach: [AppReach],
                problems: [InventoryProblem], unansweredApps: Set<String> = [], untiedSlots: [String: [CGRect]] = [:],
                activeDisplay: String? = nil, barSlots: [String: [BarSlot]] = [:], contestedApps: Set<String> = [],
                incompleteApps: Set<String> = [], appProcesses: [String: Set<Int32>] = [:], agentReadCut: Bool = false,
                runningApps: Set<String>? = nil) {
        self.capturedAt = capturedAt
        self.bars = bars
        self.items = items
        self.chevrons = chevrons
        self.reach = reach
        self.problems = problems
        self.unansweredApps = unansweredApps
        self.untiedSlots = untiedSlots
        self.activeDisplay = activeDisplay
        self.barSlots = barSlots
        self.contestedApps = contestedApps
        self.incompleteApps = incompleteApps
        self.appProcesses = appProcesses
        self.agentReadCut = agentReadCut
        self.runningApps = runningApps
    }

    /// This read, said to have been cut (`agentReadCut`).
    public func markingAgentReadCut() -> Inventory {
        Inventory(capturedAt: capturedAt, bars: bars, items: items, chevrons: chevrons, reach: reach, problems: problems,
                  unansweredApps: unansweredApps, untiedSlots: untiedSlots, activeDisplay: activeDisplay, barSlots: barSlots,
                  contestedApps: contestedApps, incompleteApps: incompleteApps, appProcesses: appProcesses, agentReadCut: true,
                  runningApps: runningApps)
    }

    /// This read, with the apps that were running when it was taken (`runningApps`).
    public func withRunningApps(_ running: Set<String>) -> Inventory {
        Inventory(capturedAt: capturedAt, bars: bars, items: items, chevrons: chevrons, reach: reach, problems: problems,
                  unansweredApps: unansweredApps, untiedSlots: untiedSlots, activeDisplay: activeDisplay, barSlots: barSlots,
                  contestedApps: contestedApps, incompleteApps: incompleteApps, appProcesses: appProcesses, agentReadCut: agentReadCut,
                  runningApps: running)
    }

    /// Equal when they say the same of the menu bar. Which display is active isn't part of what is said: a read where only the key window
    /// moved to another display is the same read, and publishes nothing new. Nor are the slots' names (`barSlots`): the frames are said
    /// by the items and `untiedSlots`, and a window that has gained a name says nothing new of the bar.
    public static func == (one: Inventory, other: Inventory) -> Bool {
        one.capturedAt == other.capturedAt && one.bars == other.bars && one.items == other.items && one.chevrons == other.chevrons
            && one.reach == other.reach && one.problems == other.problems && one.unansweredApps == other.unansweredApps
            && one.untiedSlots == other.untiedSlots && one.contestedApps == other.contestedApps && one.incompleteApps == other.incompleteApps
            && one.agentReadCut == other.agentReadCut
    }

    private enum CodingKeys: String, CodingKey {
        case capturedAt, bars, items, chevrons, reach, problems, unansweredApps, untiedSlots, activeDisplay, barSlots, contestedApps,
             incompleteApps, appProcesses, agentReadCut, runningApps
    }

    /// An inventory saved before the last eight were kept has none of them.
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
        activeDisplay = try container.decodeIfPresent(String.self, forKey: .activeDisplay)
        barSlots = try container.decodeIfPresent([String: [BarSlot]].self, forKey: .barSlots) ?? [:]
        contestedApps = try container.decodeIfPresent(Set<String>.self, forKey: .contestedApps) ?? []
        incompleteApps = try container.decodeIfPresent(Set<String>.self, forKey: .incompleteApps) ?? []
        appProcesses = try container.decodeIfPresent([String: Set<Int32>].self, forKey: .appProcesses) ?? [:]
        agentReadCut = try container.decodeIfPresent(Bool.self, forKey: .agentReadCut) ?? false
        runningApps = try container.decodeIfPresent(Set<String>.self, forKey: .runningApps)
    }

    /// What is saved is the same on every run: the sets of unanswered and contested apps are written as lists in order.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(bars, forKey: .bars)
        try container.encode(items, forKey: .items)
        try container.encode(chevrons, forKey: .chevrons)
        try container.encode(reach, forKey: .reach)
        try container.encode(problems, forKey: .problems)
        try container.encode(unansweredApps.sorted(), forKey: .unansweredApps)
        try container.encode(untiedSlots, forKey: .untiedSlots)
        try container.encodeIfPresent(activeDisplay, forKey: .activeDisplay)
        if !barSlots.isEmpty { try container.encode(barSlots, forKey: .barSlots) }
        try container.encode(contestedApps.sorted(), forKey: .contestedApps)
        if !incompleteApps.isEmpty { try container.encode(incompleteApps.sorted(), forKey: .incompleteApps) }
        if !appProcesses.isEmpty { try container.encode(appProcesses.mapValues { $0.sorted() }, forKey: .appProcesses) }
        if agentReadCut { try container.encode(true, forKey: .agentReadCut) }
        if let runningApps { try container.encode(runningApps.sorted(), forKey: .runningApps) }
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
