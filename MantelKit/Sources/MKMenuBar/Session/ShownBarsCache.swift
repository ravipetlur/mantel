import CoreGraphics
import Foundation
import MKCore

/// Which bars are on screen, as the pointer needs to know it: the list of windows is read when the pointer is near the top of a display,
/// and not more often than every quarter of a second, however many times the pointer moves.
///
/// Reading the window list isn't free, and the pointer moves a hundred times a second. The answer matters only where a bar is: a
/// pointer far from the top of every display is on no bar, whether or not a bar is shown, so nothing is read for it, and what was
/// last read is given back.
public struct ShownBarsCache: Sendable {
    /// How far below the top of a bar the pointer is still taken to be near it, in points (a bar taller than this counts whole).
    public static let nearTopDistance: CGFloat = 40
    /// How long a read of the window list is kept.
    public static let maximumAge: TimeInterval = 0.25

    private var shown: Set<String> = []
    private var readAt: Date?
    private var readFor: [MenuBarGeometry] = []

    public init() {}

    /// Whether `point` (CoreGraphics global points) is on a bar or within `nearTopDistance` of the top of one.
    public static func isNearATop(_ point: CGPoint, bars: [MenuBarGeometry]) -> Bool {
        bars.contains { bar in
            let rect = bar.rect
            return point.x >= rect.minX && point.x < rect.maxX
                && point.y >= rect.minY - 1 && point.y <= rect.minY + max(nearTopDistance, rect.height)
        }
    }

    /// The displays whose bar is on screen, for the pointer at `point`. The window list is asked for (`windows`) only when the pointer
    /// is near the top of a bar and what was read last is `maximumAge` old or more, or was read for other bars. Otherwise it is the
    /// answer of the last read, which is none before the first.
    public mutating func shownBars(at point: CGPoint, bars: [MenuBarGeometry], now: Date, windows: () -> [WindowInfo]) -> Set<String> {
        guard Self.isNearATop(point, bars: bars) else { return shown }
        if let readAt, readFor == bars, now.timeIntervalSince(readAt) < Self.maximumAge, now >= readAt { return shown }
        note(windows: windows(), bars: bars, now: now)
        return shown
    }

    /// Keeps a read of the window list that somebody else took, so that it isn't taken again at once.
    public mutating func note(windows: [WindowInfo], bars: [MenuBarGeometry], now: Date) {
        shown = BarVisibility.shownBars(windows, bars: bars)
        readAt = now
        readFor = bars
    }
}
