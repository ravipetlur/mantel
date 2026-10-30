import CoreGraphics
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

@Suite("Opened system UI", .timeLimit(.minutes(2)))
struct OpenedSystemUITests {
    private let notificationCenter = "com.apple.notificationcenterui"

    /// Two displays, in the points the window list has: the main one, and one to its left that is taller and lower.
    private let displays = [CGRect(x: 0, y: 0, width: 3360, height: 1890), CGRect(x: -1800, y: -491, width: 1800, height: 3200)]

    private func window(owner: String?, layer: Int, alpha: Double = 1, bounds: CGRect? = nil) -> WindowInfo {
        WindowInfo(number: 1, ownerPID: 100, ownerBundleID: owner, layer: layer, bounds: bounds ?? CGRect(x: 0, y: 0, width: 3360, height: 1890), alpha: alpha)
    }

    @Test func notificationCenterFullDisplayAtLayer21IsOpen() {
        #expect(OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: 21)], displays: displays))
        // Whichever display it covers.
        #expect(OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: 21, bounds: displays[1])], displays: displays))
        // At the lowest level it can have, and above it.
        #expect(OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: OpenedSystemUI.lowestLayer)], displays: displays))
        #expect(OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: 101)], displays: displays))
        // Among the windows that are on screen all the time.
        #expect(OpenedSystemUI.isOpen([window(owner: "com.example.other", layer: 0), window(owner: notificationCenter, layer: 0, bounds: CGRect(x: 100, y: 100, width: 300, height: 400)),
                                       window(owner: notificationCenter, layer: 21)], displays: displays))
        // Covering nine tenths of a display is enough, and a little less is not.
        #expect(OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: 21, bounds: CGRect(x: 0, y: 0, width: 3360, height: 1701))], displays: displays))
        #expect(!OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: 21, bounds: CGRect(x: 0, y: 0, width: 3360, height: 1700))], displays: displays))
        // More than the display is covering it too.
        #expect(OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: 21, bounds: CGRect(x: -100, y: -100, width: 5000, height: 3000))], displays: displays))
    }

    @Test func smallNotificationCenterWindowIsNot() {
        // A banner, and a widget, are windows of Notification Center that are not the panel.
        let banner = CGRect(x: 2900, y: 40, width: 420, height: 90)
        #expect(!OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: 21, bounds: banner)], displays: displays))
        #expect(!OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: 101, bounds: banner)], displays: displays))
        // A window as wide as the display and as tall as the menu bar covers little of it.
        #expect(!OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: 21, bounds: CGRect(x: 0, y: 0, width: 3360, height: 31))], displays: displays))
        // A big window that is not on a display, or covers only the part of one that two displays share.
        #expect(!OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: 21, bounds: CGRect(x: 5000, y: 0, width: 3360, height: 1890))], displays: displays))
        #expect(!OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: 21, bounds: CGRect(x: -900, y: 0, width: 1800, height: 1890))], displays: displays))
        // And below the level of the panel, whatever it covers: a widget.
        #expect(!OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: 0)], displays: displays))
        #expect(!OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: OpenedSystemUI.lowestLayer - 1)], displays: displays))
    }

    @Test func otherOwnerIsNot() {
        #expect(!OpenedSystemUI.isOpen([window(owner: "com.example.other", layer: 21)], displays: displays))
        #expect(!OpenedSystemUI.isOpen([window(owner: nil, layer: 21)], displays: displays), "a window whose owner has no bundle ID")
        #expect(!OpenedSystemUI.isOpen([], displays: displays))
        // No display to cover.
        #expect(!OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: 21)], displays: []))
        #expect(!OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: 21)], displays: [.zero, CGRect(x: 0, y: 0, width: 0, height: 100)]))
    }

    @Test func transparentIsNot() {
        #expect(!OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: 21, alpha: 0)], displays: displays))
        #expect(OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: 21, alpha: 0.01)], displays: displays))
    }

    @Test func controlCenterIsNotAnOwner() {
        // Control Center's pop-ups are not asked about: its clicks work while an allowlist is live.
        #expect(!OpenedSystemUI.isOpen([window(owner: "com.apple.controlcenter", layer: 21)], displays: displays))
        #expect(!OpenedSystemUI.isOpen([window(owner: "com.apple.controlcenter", layer: 101)], displays: displays))
        #expect(OpenedSystemUI.owners == ["com.apple.notificationcenterui"])
        #expect(WindowLevels.mainMenu == 24 && WindowLevels.statusBar == 25 && WindowLevels.popUpMenu == 101)
    }

    @Test func theDisplaysOfALayoutAreTurnedIntoWindowListPoints() {
        // A layout keeps AppKit's frames: the portrait display's frame runs from y -819 up to 2381 there, and from y -491 down to 2709 in
        // the points the window list has.
        let layout = DisplayLayout.desk
        let portraitPanel = CGRect(x: -1800, y: -491, width: 1800, height: 3200)
        #expect(OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: 21, bounds: portraitPanel)], layout: layout))
        #expect(OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: 21)], layout: layout), "the main display's")
        // The same panel in AppKit's numbers is not where the display is: it covers less than nine tenths of it.
        let inAppKitNumbers = CGRect(x: -1800, y: -819, width: 1800, height: 3200)
        #expect(!OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: 21, bounds: inAppKitNumbers)], layout: layout))
        // And with no displays there is nothing to cover.
        #expect(!OpenedSystemUI.isOpen([window(owner: notificationCenter, layer: 21)], layout: DisplayLayout(displays: [])))
    }
}
