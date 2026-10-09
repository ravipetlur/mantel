import CoreGraphics

/// One connected display, as AppKit reports it. Every rectangle is in AppKit global points: the origin is the main
/// display's bottom-left corner and y grows upwards, the space `NSScreen.frame` is in. `DisplayLayout` converts to and
/// from CoreGraphics' space, where y grows downwards from the main display's top-left corner.
public struct DisplayInfo: Codable, Sendable, Equatable {
    /// The display's UUID (`CGDisplayCreateUUIDFromDisplayID`), which stays the same across restarts and re-plugging.
    /// A display ID doesn't.
    public let uuid: String
    /// `NSScreen.localizedName`, for showing to the person.
    public let name: String
    public let frame: CGRect
    /// The part of the frame not taken by the menu bar or the Dock. It is the frame less the menu bar's height at the
    /// top, so a display that shows no menu bar has a `visibleFrame` that reaches `frame.maxY`.
    public let visibleFrame: CGRect
    /// Pixels per point.
    public let scale: CGFloat
    /// The camera housing at the top of a notched screen; nil on a screen without one.
    public let notch: CGRect?
    public let isBuiltIn: Bool
    /// Whether this is the display whose frame starts at (0, 0), the one the coordinate conversions are about.
    /// `NSScreen.main` is a different thing: the screen of the key window.
    public let isMain: Bool

    public init(uuid: String, name: String, frame: CGRect, visibleFrame: CGRect, scale: CGFloat, notch: CGRect?,
                isBuiltIn: Bool, isMain: Bool) {
        self.uuid = uuid
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.scale = scale
        self.notch = notch
        self.isBuiltIn = isBuiltIn
        self.isMain = isMain
    }
}

extension DisplayInfo {
    /// The notch's rectangle from what `NSScreen` reports, or nil when the screen has none.
    ///
    /// It runs from the right edge of the top-left area to the left edge of the top-right area, and from
    /// `safeAreaTop` below the frame's top up to the top. A screen has one only when it has a safe area at the top and
    /// both areas beside the camera housing (an area that is missing or empty doesn't count), and they leave a gap.
    static func notchRect(frame: CGRect, safeAreaTop: CGFloat, auxiliaryTopLeft: CGRect?,
                          auxiliaryTopRight: CGRect?) -> CGRect? {
        guard safeAreaTop > 0,
              let left = auxiliaryTopLeft, !left.isEmpty,
              let right = auxiliaryTopRight, !right.isEmpty,
              right.minX > left.maxX
        else { return nil }
        return CGRect(x: left.maxX, y: frame.maxY - safeAreaTop, width: right.minX - left.maxX, height: safeAreaTop)
    }
}
