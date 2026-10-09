import CoreGraphics
import MKCore

/// The display layouts the geometry and menu bar tests use, as `DisplayLayout.desk`, `.laptop` and
/// `.deskWithLaptopOpen`, built from the pieces below.
///
/// The desk's two displays carry the numbers of a real two-display setup (laptop lid closed). The laptop screen is
/// synthetic, a 14-inch notched screen's numbers, until the real one is recorded. The UUIDs are made up.
public enum DisplayFixtures {
    /// The main display, "U32J59x": 3360×1890 points at 2x, with a 31-point menu bar and a Dock along the bottom.
    public static let deskMain = DisplayInfo(
        uuid: "D4A71B63-2F5C-4E80-9B3D-6A7C8E9F0A1B",
        name: "U32J59x",
        frame: CGRect(x: 0, y: 0, width: 3360, height: 1890),
        visibleFrame: CGRect(x: 0, y: 56, width: 3360, height: 1803),
        scale: 2,
        notch: nil,
        isBuiltIn: false,
        isMain: true)

    /// The portrait display left of the main one. It reports no menu bar: its `visibleFrame` is its `frame`. Its
    /// CoreGraphics bounds are (-1800, -491, 1800, 3200).
    public static let deskPortrait = DisplayInfo(
        uuid: "8C2D5F14-3E6A-4B79-A1D0-9F8E7D6C5B4A",
        name: "LG HDR 4K",
        frame: CGRect(x: -1800, y: -819, width: 1800, height: 3200),
        visibleFrame: CGRect(x: -1800, y: -819, width: 1800, height: 3200),
        scale: 2,
        notch: nil,
        isBuiltIn: false,
        isMain: false)

    /// The laptop's built-in screen on its own, so at the origin: 1512×982 points at 2x with a 32-point menu bar and
    /// a 186×32 notch in the middle of it.
    public static let laptopAlone = DisplayInfo(
        uuid: "7B0E1E64-5D0F-4F5B-9A53-1C2D3E4F5A6B",
        name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        scale: 2,
        notch: CGRect(x: 663, y: 950, width: 186, height: 32),
        isBuiltIn: true,
        isMain: true)

    /// The same screen with the lid open beside the desk: right of the main display, at x = 3360. It is not the main
    /// display then, and its `frame`, `visibleFrame` and `notch` all sit 3360 points to the right.
    public static let laptopRightOfDesk = DisplayInfo(
        uuid: laptopAlone.uuid,
        name: laptopAlone.name,
        frame: CGRect(x: 3360, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 3360, y: 0, width: 1512, height: 950),
        scale: 2,
        notch: CGRect(x: 4023, y: 950, width: 186, height: 32),
        isBuiltIn: true,
        isMain: false)
}

extension DisplayLayout {
    /// A desk with the lid closed: the main display and the portrait one to its left.
    public static let desk = DisplayLayout(displays: [DisplayFixtures.deskMain, DisplayFixtures.deskPortrait])

    /// The laptop on its own: one notched, built-in display, which is the main display.
    public static let laptop = DisplayLayout(displays: [DisplayFixtures.laptopAlone])

    /// `desk` plus the laptop, lid open, to the right of the main display.
    public static let deskWithLaptopOpen = DisplayLayout(displays: [
        DisplayFixtures.deskMain, DisplayFixtures.deskPortrait, DisplayFixtures.laptopRightOfDesk,
    ])
}
