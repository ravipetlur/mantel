import CoreGraphics
import Foundation
import MKCommands
import MKCore

/// What AppKit says of one screen, for the question the notch asks: where the areas beside the camera housing are, and in which
/// coordinates.
public struct ScreenFacts: Sendable, Codable, Equatable {
    public let uuid: String
    /// AppKit global points.
    public let frame: CGRect
    public let safeAreaTop: CGFloat
    /// `NSScreen.auxiliaryTopLeftArea` and `auxiliaryTopRightArea`: the usable strips either side of the housing. Nil on a screen
    /// without one.
    public let auxiliaryTopLeft: CGRect?
    public let auxiliaryTopRight: CGRect?
    public let isBuiltIn: Bool

    public init(uuid: String, frame: CGRect, safeAreaTop: CGFloat, auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?, isBuiltIn: Bool) {
        self.uuid = uuid
        self.frame = frame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
        self.isBuiltIn = isBuiltIn
    }
}

/// Whether the areas beside the notch are in global coordinates or in the screen's own (zero-based). Only a screen that isn't at the
/// origin can tell: at the origin the two are the same numbers.
public enum NotchCoordinates {
    public enum Verdict: String, Codable, Sendable {
        /// Inside the screen's frame, which is where that frame is in the whole arrangement.
        case global
        /// Inside a frame of the screen's size at the origin.
        case screenLocal
        /// The screen is at the origin, has no such areas, or they fit both or neither.
        case undecided
    }

    /// Within half a point, for the rounding of a frame that isn't whole points.
    private static let tolerance: CGFloat = 0.5

    public static func verdict(_ screen: ScreenFacts) -> Verdict {
        guard screen.frame.origin != .zero else { return .undecided }
        let areas = [screen.auxiliaryTopLeft, screen.auxiliaryTopRight].compactMap { $0 }.filter { !$0.isEmpty }
        guard !areas.isEmpty else { return .undecided }
        let global = screen.frame.insetBy(dx: -tolerance, dy: -tolerance)
        let local = CGRect(origin: .zero, size: screen.frame.size).insetBy(dx: -tolerance, dy: -tolerance)
        let isGlobal = areas.allSatisfy(global.contains)
        let isLocal = areas.allSatisfy(local.contains)
        switch (isGlobal, isLocal) {
        case (true, false): return .global
        case (false, true): return .screenLocal
        default: return .undecided
        }
    }
}

/// `notch-coordinates`: for every screen, what AppKit says of it (frame, the top safe area, the areas beside the camera housing,
/// whether it is the built-in one), whether those areas are in global or in the screen's own coordinates, and MenuBarAgent's window
/// that lies on it (`barFrame`, in CoreGraphics points). Run it with the lid open and an external display as the main one: that is
/// the arrangement where the built-in screen isn't at the origin, and the only one that tells. Only reads.
enum NotchCoordinatesProbe {
    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        let screens = await context.platform.screens()
        let layout = await context.layoutProvider()
        let snapshot = await context.agentSnapshot()
        for problem in snapshot.problems { recorder.note(problem) }

        var reports: [JSONValue] = []
        for screen in screens {
            let verdict = NotchCoordinates.verdict(screen)
            let area = layout.cgRect(fromAppKit: screen.frame)
            let bar = snapshot.agentWindows.first { area.contains($0.frame.origin) }
            reports.append(.object([
                "uuid": .string(screen.uuid),
                "frame": rect(screen.frame),
                "safeAreaTop": .number(screen.safeAreaTop),
                "auxiliaryTopLeft": screen.auxiliaryTopLeft.map(rect) ?? .null,
                "auxiliaryTopRight": screen.auxiliaryTopRight.map(rect) ?? .null,
                "isBuiltIn": .bool(screen.isBuiltIn),
                "verdict": .string(verdict.rawValue),
                "barFrame": bar.map { rect($0.frame) } ?? .null,
            ]))
        }
        recorder.measure("screens", .array(reports))
        recorder.measure("verdicts", strings: screens.map { NotchCoordinates.verdict($0).rawValue })
        if !screens.contains(where: { $0.frame.origin != .zero && ($0.auxiliaryTopLeft != nil || $0.auxiliaryTopRight != nil) }) {
            recorder.note("No screen that is away from the origin has areas beside a notch, so nothing could be decided. Open the lid with an external display as the main one and run it again.")
        }
        recorder.note("frame and the areas are AppKit points; barFrame is CoreGraphics points.")
    }

    static func rect(_ rect: CGRect) -> JSONValue {
        .object(["x": .number(rect.minX), "y": .number(rect.minY), "width": .number(rect.width), "height": .number(rect.height)])
    }
}
