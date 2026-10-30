import CoreGraphics
import Testing

@testable import MKMenuBar

@Suite("Window rules", .timeLimit(.minutes(2)))
struct WindowRulesTests {
    private func window(layer: Int, alpha: Double = 1, owner: String? = "com.example.weather") -> WindowInfo {
        WindowInfo(number: 1, ownerPID: 100, ownerBundleID: owner, layer: layer, bounds: CGRect(x: 3000, y: 30, width: 240, height: 300), alpha: alpha)
    }

    @Test func menuAtPopUpLevelIsOpen() {
        #expect(WindowRules.isMenuOpen([window(layer: 101)]))
        #expect(WindowRules.isMenuOpen([window(layer: WindowLevels.popUpMenu)]))
        // Whoever owns it: an app's menu and a status item's are both there.
        #expect(WindowRules.isMenuOpen([window(layer: 101, owner: nil)]))
        // Among the windows that are always on screen.
        #expect(WindowRules.isMenuOpen([window(layer: 0), window(layer: WindowLevels.mainMenu), window(layer: WindowLevels.statusBar), window(layer: 101)]))
        // A little see-through is still there.
        #expect(WindowRules.isMenuOpen([window(layer: 101, alpha: 0.01)]))
    }

    @Test func highUtilityWindowIsNotAMenu() {
        // Floating panels, the status items' own windows and utility windows sit near 101 and are not menus: only the level itself is.
        for layer in [0, 3, 8, WindowLevels.mainMenu, WindowLevels.statusBar, 100, 102, 200, 1000] {
            #expect(!WindowRules.isMenuOpen([window(layer: layer)]), "level \(layer)")
        }
        #expect(!WindowRules.isMenuOpen([]))
    }

    @Test func transparentMenuIsNot() {
        // A menu that has faded out, or whose window is kept around invisible, is closed.
        #expect(!WindowRules.isMenuOpen([window(layer: 101, alpha: 0)]))
        // Another that is shown makes it open.
        #expect(WindowRules.isMenuOpen([window(layer: 101, alpha: 0), window(layer: 101, alpha: 1)]))
    }
}
