import Foundation

/// The moments at which the menu bar's icons are captured.
public enum CaptureMoment: Sendable, Equatable {
    /// The first read at launch, while everything is still drawn.
    case launch
    /// A reveal whose follow-up read saw these apps (bundle IDs) drawn.
    case revealSeen(Set<String>)
    /// An icon that was clicked is now drawn.
    case clickDrawn(ItemLocation)
    /// Settings › Layout opened.
    case settingsOpened
    /// The person asked to recapture.
    case recapture

    public var kind: CaptureMomentKind {
        switch self {
        case .launch: .launch
        case .revealSeen: .revealSeen
        case .clickDrawn: .clickDrawn
        case .settingsOpened: .settingsOpened
        case .recapture: .recapture
        }
    }
}

public enum CaptureMomentKind: String, Sendable, CaseIterable {
    case launch, revealSeen, clickDrawn, settingsOpened, recapture
}

/// When pictures are taken and how often. The values come from the caller, as what the platform check found decides some of them.
public struct CaptureRules: Sendable, Equatable {
    /// The moments that capture; the others are skipped.
    public var moments: Set<CaptureMomentKind>
    /// The least time between two captures of one bar.
    public var perBarInterval: Duration
    /// How long a picture of a steady icon is kept before it is taken again.
    public var freshFor: Duration
    /// The most time the launch capture takes, after which the first plan applies anyway.
    public var launchBudget: Duration
    /// The time each shown bar adds to the launch capture's budget, which `launchBudget` caps; nil for one budget whatever the bars.
    public var launchBudgetPerBar: Duration?
    /// How long after a capture the session ignores the recording indicator's item. The collector doesn't use it; it is carried here for
    /// the session.
    public var indicatorQuietPeriod: Duration?

    public init(moments: Set<CaptureMomentKind>, perBarInterval: Duration = .seconds(2), freshFor: Duration = .seconds(3600),
                launchBudget: Duration, launchBudgetPerBar: Duration? = nil, indicatorQuietPeriod: Duration? = nil) {
        self.moments = moments
        self.perBarInterval = perBarInterval
        self.freshFor = freshFor
        self.launchBudget = launchBudget
        self.launchBudgetPerBar = launchBudgetPerBar
        self.indicatorQuietPeriod = indicatorQuietPeriod
    }

    /// How long the launch capture may take with this many bars shown: each bar's share, and never more than `launchBudget`.
    public func budget(forShownBars count: Int) -> Duration {
        guard let launchBudgetPerBar else { return launchBudget }
        return min(launchBudget, launchBudgetPerBar * max(count, 1))
    }

    /// The most a busy Mac adds to the launch capture's budget.
    public static let busyMacAllowance: Duration = .seconds(2)

    /// The launch capture's budget (`budget(forShownBars:)`), and, when the read it follows was slow, as much again as that read took: the
    /// checks that come with the picture (the bar and the apps' frames, looked at once more) are reads of the same Mac and take about as
    /// long, and a budget that is made for a Mac that isn't busy would lose the capture on one that is. Never more than
    /// `busyMacAllowance` more.
    public func launchBudget(forShownBars count: Int, readTook: TimeInterval) -> Duration {
        let slow = max(0, readTook - 0.1)
        let extra = min(Duration.seconds(slow), Self.busyMacAllowance)
        return budget(forShownBars: count) + extra
    }

    /// One budget for the launch capture whatever the bars, and nothing measured: for a caller that has no results of its own.
    public static let provisional = CaptureRules(moments: Set(CaptureMomentKind.allCases), launchBudget: .seconds(1),
                                                 indicatorQuietPeriod: nil)

    // From the platform check's results
    public static let measured = CaptureRules(moments: Set(CaptureMomentKind.allCases), launchBudget: .seconds(1),
                                              launchBudgetPerBar: .milliseconds(226), indicatorQuietPeriod: nil)
}

/// What one capture did.
public struct CaptureSummary: Sendable, Equatable {
    /// Pictures taken and kept.
    public let captured: Int
    /// Of those, the ones that came out different from what was kept (or new).
    public let changed: Int
    /// Why nothing was captured, when nothing was.
    public let skipped: String?

    public init(captured: Int, changed: Int, skipped: String?) {
        self.captured = captured
        self.changed = changed
        self.skipped = skipped
    }
}
