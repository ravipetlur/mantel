import CoreGraphics
import MKCore

/// Why the plan is what it is: the highest of the layers that built it. Each layer overrides the ones below it; from the lowest:
/// the person's sections, rules, a wide screen, an icon the person asked for, a reveal, Focus Mode. (What the plan shows is another matter:
/// an icon asked for is shown whatever Focus Mode says, but the reason the plan gives is the highest of these.)
public enum PlanSource: Codable, Sendable, Equatable {
    case sections
    case focusMode
    case reveal(RevealLevel)
    case wideScreen
    case rules
    case iconReveal

    /// The reason in words, for Diagnostics.
    public var explanation: String {
        switch self {
        case .sections, .reveal(.off): "Your sections"
        case .focusMode: "Focus Mode is on"
        case .reveal(.hidden): "Showing hidden icons"
        case .reveal(.all): "Showing all icons"
        case .iconReveal: "Showing an icon you asked for"
        case .wideScreen: "This screen is wide, so everything shows"
        case .rules: "A rule is showing icons"
        }
    }
}

/// What the menu bar should show right now. Every engine hides what the plan conceals and leaves the rest alone.
public struct VisibilityPlan: Codable, Sendable, Equatable {
    /// Every number macOS's allowlist of system items can name.
    public static let allSystemItems: ClosedRange<Int> = 0...255

    /// The apps whose icons stay on the bar: every running app the plan doesn't conceal, and Mantel itself, always.
    public var visibleBundleIDs: Set<String>
    /// The running apps whose icons the plan takes off the bar. Never Mantel. An app that is placed in a section but isn't running
    /// is in neither set.
    public var concealedBundleIDs: Set<String>
    /// The numbers of the system items that stay: every number, less those of the system items the plan conceals. A system item
    /// Mantel doesn't know has no number to take away, so it stays.
    public var visibleSystemItems: Set<Int>
    /// The sections whose icons the plan conceals as a whole. (A rule or a swap that conceals one app doesn't name a section.)
    public var concealedSections: Set<MenuBarSection>
    public var source: PlanSource

    public init(visibleBundleIDs: Set<String>, concealedBundleIDs: Set<String>, visibleSystemItems: Set<Int>,
                concealedSections: Set<MenuBarSection>, source: PlanSource) {
        self.visibleBundleIDs = visibleBundleIDs
        self.concealedBundleIDs = concealedBundleIDs
        self.visibleSystemItems = visibleSystemItems
        self.concealedSections = concealedSections
        self.source = source
    }

    /// The plan hides no app and no system item.
    public var concealsNothing: Bool {
        concealedBundleIDs.isEmpty && Self.allSystemItems.allSatisfy(visibleSystemItems.contains)
    }
}

/// What a rule does to the plan.
public enum RuleEffect: Sendable, Equatable {
    /// These apps (by bundle ID) are shown whatever section they are in.
    case show(Set<String>)
}

/// What the plan needs to know about the screen the person is working on.
public struct WideScreenInput: Sendable, Equatable {
    /// Whether the person has asked for everything to show on a wide screen.
    public var enabled: Bool
    /// In points: a screen wider than this counts as wide.
    public var threshold: Int
    /// The width of the screen the pointer or the front window is on.
    public var activeScreenWidth: CGFloat

    public init(enabled: Bool, threshold: Int, activeScreenWidth: CGFloat) {
        self.enabled = enabled
        self.threshold = threshold
        self.activeScreenWidth = activeScreenWidth
    }

    /// The screen is wider than the threshold and the person asked for this.
    public var applies: Bool {
        enabled && activeScreenWidth > CGFloat(threshold)
    }
}

/// Everything `PlanBuilder` turns into a plan.
public struct PlanInputs: Sendable, Equatable {
    public var ownBundleID: String
    /// Every running app that has a bundle ID, the ones with no windows and no Dock icon included: such an app can still have an
    /// icon in the menu bar, and one left out would have it concealed.
    public var runningBundleIDs: [String]
    public var sections: SectionModel
    public var reveal: RevealLevel
    public var focusMode: Bool
    public var rules: [RuleEffect]
    public var allowHidingClockAndControlCenter: Bool
    public var wideScreen: WideScreenInput
    /// The Shown apps that a swap conceals to make room while something is revealed.
    public var swapConcealed: Set<String>
    /// The icons that something asked to have shown (one click, one look), wherever they are hidden. The top layer: they are shown whatever
    /// Focus Mode says.
    public var iconReveals: Set<ItemID>
    /// The Shown apps that are concealed to make room for an icon in `iconReveals`. Concealed only while there is one.
    public var iconRoomConcealed: Set<String>

    public init(ownBundleID: String, runningBundleIDs: [String], sections: SectionModel, reveal: RevealLevel, focusMode: Bool,
                rules: [RuleEffect] = [], allowHidingClockAndControlCenter: Bool, wideScreen: WideScreenInput,
                swapConcealed: Set<String> = [], iconReveals: Set<ItemID> = [], iconRoomConcealed: Set<String> = []) {
        self.ownBundleID = ownBundleID
        self.runningBundleIDs = runningBundleIDs
        self.sections = sections
        self.reveal = reveal
        self.focusMode = focusMode
        self.rules = rules
        self.allowHidingClockAndControlCenter = allowHidingClockAndControlCenter
        self.wideScreen = wideScreen
        self.swapConcealed = swapConcealed
        self.iconReveals = iconReveals
        self.iconRoomConcealed = iconRoomConcealed
    }
}
