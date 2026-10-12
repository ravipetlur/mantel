import CoreGraphics
import MKCore

/// The display layouts the geometry and menu bar tests use, as `DisplayLayout.desk`, `.laptop` and
/// `.deskWithLaptopOpen`, built from the pieces below.
///
/// The desk's two displays and the laptop's built-in screen carry the numbers of a real setup. The UUIDs are made up.
public enum DisplayFixtures {
    /// The main display, "Desk Display": 3360×1890 points at 2x, with a Dock along the bottom. Its `visibleFrame` leaves 31 points for
    /// the menu bar, whose own window is 30.
    public static let deskMain = DisplayInfo(
        uuid: "D4A71B63-2F5C-4E80-9B3D-6A7C8E9F0A1B",
        name: "Desk Display",
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
        name: "Side Display",
        frame: CGRect(x: -1800, y: -819, width: 1800, height: 3200),
        visibleFrame: CGRect(x: -1800, y: -819, width: 1800, height: 3200),
        scale: 2,
        notch: nil,
        isBuiltIn: false,
        isMain: false)

    /// The laptop's built-in screen on its own, so at the origin, as it was recorded: 1728×1117 points at 2x, with a 185×32 notch
    /// in the middle of the top edge. Its menu bar is 33 points high (MenuBarAgent's window), while its `visibleFrame` leaves 34.
    public static let laptopAlone = DisplayInfo(
        uuid: "7B0E1E64-5D0F-4F5B-9A53-1C2D3E4F5A6B",
        name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1083),
        scale: 2,
        notch: CGRect(x: 771.5, y: 1085, width: 185, height: 32),
        isBuiltIn: true,
        isMain: true)

    /// The same screen with the lid open beside the desk: right of the main display, at x = 3360. It is not the main
    /// display then, and its `frame`, `visibleFrame` and `notch` all sit 3360 points to the right.
    public static let laptopRightOfDesk = DisplayInfo(
        uuid: laptopAlone.uuid,
        name: laptopAlone.name,
        frame: CGRect(x: 3360, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 3360, y: 0, width: 1728, height: 1083),
        scale: 2,
        notch: CGRect(x: 4131.5, y: 1085, width: 185, height: 32),
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
