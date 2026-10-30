import Foundation
import Synchronization

/// The value of `choices` that is nearest to `value`; the lower of two that are equally near.
///
/// `value` is brought within the range of `choices` first, so that the distance to a choice is a small number whatever a file says:
/// the distance to `Int.min` would overflow, and the nearest choice to a value beyond the range is the end of it either way.
private func nearest(to value: Int, in choices: [Int]) -> Int {
    guard let lowest = choices.min(), let highest = choices.max() else { return value }
    let clamped = min(max(value, lowest), highest)
    return choices.min { abs($0 - clamped) < abs($1 - clamped) } ?? clamped
}

/// How long a reveal lasts before the icons are hidden again.
///
/// It is written to `settings.json` as a plain value: the number of seconds (`10`), or the word `never`. A number of seconds
/// that isn't one of `choices` (a file edited by hand) is read as the nearest one.
public enum RehideDelay: Codable, Sendable, Equatable, Hashable {
    case seconds(Int)
    case never

    /// The seconds Settings offers.
    public static let choices = [5, 10, 15, 30, 60]

    private static let neverWord = "never"

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Int.self) {
            self = .seconds(nearest(to: seconds, in: Self.choices))
        } else if try container.decode(String.self) == Self.neverWord {
            self = .never
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "A rehide delay is a number of seconds or \"never\".")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .seconds(let seconds): try container.encode(seconds)
        case .never: try container.encode(Self.neverWord)
        }
    }
}

/// What reveals the hidden icons besides the dots and the hotkeys, and for how long. Kept in `settings.json` under `reveal`; a
/// key missing from the file takes its default.
public struct RevealSettings: Codable, Sendable, Equatable {
    /// Moving the pointer to empty space in the menu bar reveals Hidden.
    public var hoverReveals = false
    /// Clicking empty space in the menu bar reveals Hidden.
    public var clickReveals = false
    /// Scrolling down on the menu bar reveals Hidden; scrolling up hides it again.
    public var scrollReveals = false
    /// How long the pointer rests in empty space before a hover reveals: 100, 200, 300, 500 or 800 (a file that says another number
    /// is read as the nearest of these).
    public var hoverDelayMilliseconds = 300
    /// How long after the last reveal the icons are hidden again: 5, 10, 15, 30 or 60 seconds, or never.
    public var rehide: RehideDelay = .seconds(10)

    /// The delays Settings offers.
    public static let hoverDelayChoices = [100, 200, 300, 500, 800]

    /// Whether the pointer on the menu bar can reveal anything: hover, click or scroll is on. The app listens for the pointer only
    /// then.
    public var usesPointer: Bool {
        hoverReveals || clickReveals || scrollReveals
    }

    public init() {}

    public init(hoverReveals: Bool, clickReveals: Bool, scrollReveals: Bool, hoverDelayMilliseconds: Int, rehide: RehideDelay) {
        self.hoverReveals = hoverReveals
        self.clickReveals = clickReveals
        self.scrollReveals = scrollReveals
        self.hoverDelayMilliseconds = hoverDelayMilliseconds
        self.rehide = rehide
    }

    private enum CodingKeys: String, CodingKey {
        case hoverReveals, clickReveals, scrollReveals, hoverDelayMilliseconds, rehide
    }

    // A key missing from the file takes its default, so a file written before a key was added is still read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RevealSettings()
        self.init(hoverReveals: try container.decodeIfPresent(Bool.self, forKey: .hoverReveals) ?? defaults.hoverReveals,
                  clickReveals: try container.decodeIfPresent(Bool.self, forKey: .clickReveals) ?? defaults.clickReveals,
                  scrollReveals: try container.decodeIfPresent(Bool.self, forKey: .scrollReveals) ?? defaults.scrollReveals,
                  hoverDelayMilliseconds: nearest(
                      to: try container.decodeIfPresent(Int.self, forKey: .hoverDelayMilliseconds) ?? defaults.hoverDelayMilliseconds,
                      in: Self.hoverDelayChoices),
                  rehide: try container.decodeIfPresent(RehideDelay.self, forKey: .rehide) ?? defaults.rehide)
    }
}

/// Which way Mantel hides icons.
public enum HidingMethodChoice: String, Codable, Sendable, CaseIterable {
    /// The best way that works on this Mac.
    case automatic
    /// The "Allow in the Menu Bar" switches in System Settings.
    case systemSettingsSwitches
    /// A wide invisible item that pushes the icons off the bar. It isn't offered in Settings any more: it is what Automatic falls back to
    /// when nothing else can be used. A file that still says it is read as `automatic` (`HidingSettings`), and the file still decodes.
    case wideSpacer

    /// Whether Settings offers it.
    public var isOffered: Bool {
        self != .wideSpacer
    }
}

/// What Mantel does when revealed icons don't all fit on the bar.
public enum NoRoomPolicy: String, Codable, Sendable, CaseIterable {
    /// Show the revealed icons on a bar of their own, under the menu bar.
    case secondBar
    /// Hide the Shown icons that are furthest right to make room.
    case swap
    /// Hide the front app's menus to make room.
    case hideAppMenus
}

/// How icons are hidden, and the exceptions. Kept in `settings.json` under `hiding`; a key missing from the file takes its default.
public struct HidingSettings: Codable, Sendable, Equatable {
    public var method: HidingMethodChoice = .automatic
    /// Whether the clock and Control Center can be put in Hidden and Always Hidden. Off, they stay on the bar whatever section
    /// they are in.
    public var allowHidingClockAndControlCenter = false
    public var noRoomPolicy: NoRoomPolicy = .secondBar
    /// Whether icons that don't fit on the bar (the « overflow, the notch) are moved to Hidden for you.
    public var automaticOverflow = true
    /// Whether nothing is hidden on a screen wider than `wideScreenThreshold`.
    public var showEverythingOnWideScreens = false
    /// Points, from 1000 to 10000 in steps of 100 (a file that says another number is read as the nearest of these).
    public var wideScreenThreshold = 3000

    /// The thresholds Settings offers: 1000, 1100, … 10000.
    public static let wideScreenThresholdRange = 1000...10000
    public static let wideScreenThresholdStep = 100

    public init() {}

    public init(method: HidingMethodChoice, allowHidingClockAndControlCenter: Bool, noRoomPolicy: NoRoomPolicy,
                automaticOverflow: Bool, showEverythingOnWideScreens: Bool, wideScreenThreshold: Int) {
        self.method = method
        self.allowHidingClockAndControlCenter = allowHidingClockAndControlCenter
        self.noRoomPolicy = noRoomPolicy
        self.automaticOverflow = automaticOverflow
        self.showEverythingOnWideScreens = showEverythingOnWideScreens
        self.wideScreenThreshold = wideScreenThreshold
    }

    private enum CodingKeys: String, CodingKey {
        case method, allowHidingClockAndControlCenter, noRoomPolicy, automaticOverflow, showEverythingOnWideScreens, wideScreenThreshold
    }

    /// Said once for as long as Mantel runs, when a saved method that isn't offered any more is read as Automatic.
    static let noLongerOfferedLine = "the saved hiding method is no longer offered; Mantel uses Automatic"
    private static let noLongerOfferedLogged = Mutex(false)

    // A key missing from the file takes its default, so a file written before a key was added is still read; so does a method or a choice
    // for icons that don't fit that this version doesn't know (a file a newer Mantel saved), and the rest of the file is read as it is. A
    // method that isn't offered any more is read as Automatic.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = HidingSettings()
        var method = container.decodeLeniently(HidingMethodChoice.self, forKey: .method) ?? defaults.method
        if !method.isOffered {
            method = .automatic
            let first = Self.noLongerOfferedLogged.withLock { logged in
                defer { logged = true }
                return !logged
            }
            if first { Log.info("settings", Self.noLongerOfferedLine) }
        }
        self.init(method: method,
                  allowHidingClockAndControlCenter: try container.decodeIfPresent(Bool.self, forKey: .allowHidingClockAndControlCenter)
                      ?? defaults.allowHidingClockAndControlCenter,
                  noRoomPolicy: container.decodeLeniently(NoRoomPolicy.self, forKey: .noRoomPolicy) ?? defaults.noRoomPolicy,
                  automaticOverflow: try container.decodeIfPresent(Bool.self, forKey: .automaticOverflow) ?? defaults.automaticOverflow,
                  showEverythingOnWideScreens: try container.decodeIfPresent(Bool.self, forKey: .showEverythingOnWideScreens)
                      ?? defaults.showEverythingOnWideScreens,
                  wideScreenThreshold: Self.snapped(
                      try container.decodeIfPresent(Int.self, forKey: .wideScreenThreshold) ?? defaults.wideScreenThreshold))
    }

    /// A threshold within the range and on a step: the nearest one, the higher of two that are equally near. A file says it this way,
    /// and so does the field in Settings when it is committed (`wideScreenThresholdFormat`).
    private static func snapped(_ threshold: Int) -> Int {
        ClampedIntegerFormat.clamped(threshold, to: wideScreenThresholdRange, step: wideScreenThresholdStep)
    }

    /// How the field for the threshold shows a number and reads one.
    public static let wideScreenThresholdFormat = ClampedIntegerFormat(range: wideScreenThresholdRange, step: wideScreenThresholdStep)
}
