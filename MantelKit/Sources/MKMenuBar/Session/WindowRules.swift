/// What the list of windows on screen says about what the person is doing.
public enum WindowRules {
    /// Whether a menu is open: a window at the pop-up level (`WindowLevels.popUpMenu`, where the menus of apps and of status items are)
    /// that can be seen (`alpha` above zero). `windows` are the ones on screen.
    ///
    /// While one is open the icons revealed on the bar are not hidden again: the menu belongs to one of them.
    public static func isMenuOpen(_ windows: [WindowInfo]) -> Bool {
        windows.contains { $0.layer == WindowLevels.popUpMenu && $0.alpha > 0 }
    }
}
