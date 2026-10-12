import CoreGraphics

/// Which Shown apps to hide, for a moment, to make room for what a reveal brings onto the bar.
public enum SwapCalculator {
    /// The most times a swap looks again after hiding some apps and finding that the bar still has no room.
    public static let maximumRounds = 3

    /// The apps to conceal to free `needed` points: the right-most first, one after another, until their widths add up to `needed`
    /// or more. An app in `never` (Mantel's own, the system's) is passed over. If all the apps there are don't add up to `needed`,
    /// all of them are returned: that is as much room as can be made.
    ///
    /// `shownRightToLeft` lists the Shown apps with the width of everything each draws, the right-most app first.
    public static func appsToConceal(needed: CGFloat, shownRightToLeft: [(bundleID: String, width: CGFloat)],
                                     never: Set<String>) -> Set<String> {
        var concealed: Set<String> = []
        var freed: CGFloat = 0
        for app in shownRightToLeft where freed < needed {
            guard !never.contains(app.bundleID) else { continue }
            concealed.insert(app.bundleID)
            freed += app.width
        }
        return concealed
    }
}
