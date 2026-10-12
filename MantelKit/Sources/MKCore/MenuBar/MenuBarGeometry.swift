import CoreGraphics

/// One display's menu bar, as MenuBarAgent draws it: where it is and how tall, which is what macOS says and not what a
/// display's `visibleFrame` suggests (that is off by a point or two, and says 0 while the bar is set to hide).
public struct MenuBarGeometry: Codable, Sendable, Equatable {
    /// The display it is on (`DisplayInfo.uuid`).
    public let displayUUID: String
    /// MenuBarAgent's window for that display, in CoreGraphics global points.
    public let rect: CGRect
    /// The camera housing, in CoreGraphics global points; nil on a display without one.
    public let notch: CGRect?

    public var height: CGFloat { rect.height }

    public init(displayUUID: String, rect: CGRect, notch: CGRect?) {
        self.displayUUID = displayUUID
        self.rect = rect
        self.notch = notch
    }
}
