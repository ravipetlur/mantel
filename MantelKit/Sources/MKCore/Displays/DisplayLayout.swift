import CoreGraphics

/// All connected displays, and the conversions between the two coordinate spaces the menu bar code lives in.
///
/// - **AppKit** (`NSScreen.frame`, `NSEvent.mouseLocation`, window frames): global points, the origin at the main
///   display's bottom-left corner, y up.
/// - **CoreGraphics** (`CGDisplayBounds`, event taps, `CGWindowList`, the Accessibility API): global points, the origin
///   at the main display's top-left corner, y down.
///
/// Both spaces have the same x. They differ in y by a flip about the main display's height, so every conversion is
/// `mainHeight - y`.
public struct DisplayLayout: Codable, Sendable, Equatable {
    public let displays: [DisplayInfo]

    public init(displays: [DisplayInfo]) {
        self.displays = displays
    }

    /// The displays' UUIDs as a set; the same displays give the same fingerprint in any order and arrangement.
    public var fingerprint: DisplayFingerprint {
        DisplayFingerprint(uuids: displays.map(\.uuid))
    }

    /// The display whose frame starts at (0, 0), the axis of the conversions. This is not `NSScreen.main`, which is the
    /// screen of the key window and moves as the person clicks around. Nil only for a layout without displays.
    public var main: DisplayInfo? {
        displays.first { $0.frame.origin == .zero }
    }

    /// The display that has this AppKit point on it.
    ///
    /// A display owns its left and top edges, so the point at the very top of the screen, where a pointer pushed up
    /// against the menu bar lands (`NSEvent.mouseLocation` is `frame.maxY` there), is on that display and not above
    /// it, and an edge two displays share belongs to just one of them whatever order they are listed in. A point on
    /// the right or bottom edge of the whole arrangement, where no display takes over, still finds the display it is
    /// the edge of. A point in the empty space between displays, or past them, is nil.
    ///
    /// When more than one display has a claim on the point (a corner two displays meet at, where neither's half-open area has
    /// it, or displays that overlap), the one that comes first by where it is on the screen has it: the leftmost, then the lowest,
    /// then by its UUID. The answer never depends on the order the displays are listed in.
    public func display(containing appKitPoint: CGPoint) -> DisplayInfo? {
        let owners = displays.filter { $0.owns(appKitPoint) }
        let claimants = owners.isEmpty ? displays.filter { $0.frame.hasOnItsBoundary(appKitPoint) } : owners
        return claimants.min(by: DisplayInfo.comesFirstOnScreen)
    }

    public func display(uuid: String) -> DisplayInfo? {
        displays.first { $0.uuid == uuid }
    }

    // MARK: AppKit ⇄ CoreGraphics

    /// The height of the main display, the line the two spaces flip about. A layout without displays has no axis, so
    /// nothing is flipped about anything: it converts with a height of 0, and callers that can see one check `main`.
    private var axis: CGFloat {
        main?.frame.height ?? 0
    }

    public func appKitPoint(fromCG p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: axis - p.y)
    }

    public func cgPoint(fromAppKit p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: axis - p.y)
    }

    /// A rectangle's origin is its bottom-left corner in AppKit and its top-left corner in CoreGraphics, so the
    /// flipped y is the one of the rectangle's other edge: `mainHeight - (y + height)`.
    public func appKitRect(fromCG r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: axis - r.maxY, width: r.width, height: r.height)
    }

    public func cgRect(fromAppKit r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: axis - r.maxY, width: r.width, height: r.height)
    }
}

extension DisplayInfo {
    /// The order that settles a point two displays have a claim on: by the left edge, then the bottom edge, then the UUID, which no
    /// two displays share.
    fileprivate static func comesFirstOnScreen(_ one: DisplayInfo, _ other: DisplayInfo) -> Bool {
        (one.frame.minX, one.frame.minY, one.uuid) < (other.frame.minX, other.frame.minY, other.uuid)
    }

    /// Whether the point is on this display, treating the frame as the half-open area CoreGraphics gives a display
    /// (`minX <= x < maxX`, and top row in, bottom row out), flipped into AppKit's y: `minY < y <= maxY`.
    fileprivate func owns(_ point: CGPoint) -> Bool {
        point.x >= frame.minX && point.x < frame.maxX && point.y > frame.minY && point.y <= frame.maxY
    }
}

extension CGRect {
    /// Whether the point is inside the rectangle or on any of its four edges.
    fileprivate func hasOnItsBoundary(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}
