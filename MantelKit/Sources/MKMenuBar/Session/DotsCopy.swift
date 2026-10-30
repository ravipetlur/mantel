import Foundation
import MKLayout

/// The words of the two dots in the menu bar: what each is called for the accessibility tools, what the tooltip says, and the menu.
///
/// The names and descriptions are Mantel's own items' (`OwnItems`), which is where the layout keeps them, so that what finds an item and
/// what names it are the same words.
public enum DotsCopy {
    /// What the system keeps each dot's place in the menu bar under (the status item's autosave name), and the name an item that tells it
    /// has: • is the first and •• the second. These two names are what makes an item of Mantel's a dot (`isDot`).
    public static let hiddenDotName = OwnItems.hiddenDotName
    public static let alwaysDotName = OwnItems.alwaysDotName

    /// Whether an item of Mantel's is one of the dots: by the name it carries, or (the menu bar's Accessibility tree gives no names for
    /// status items) by what it is called for the accessibility tools, which is Mantel's own text. The wide spacer's invisible items have
    /// neither. It is `OwnItems.kind` saying a dot.
    public static func isDot(name: String?, description: String?) -> Bool {
        OwnItems.kind(name: name, description: description)?.isDot == true
    }

    /// What • is called: it shows the icons in Hidden.
    public static let hiddenDotDescription = OwnItems.hiddenDotDescription
    /// What •• is called: it shows the icons in Hidden and in Always Hidden.
    public static let alwaysDotDescription = OwnItems.alwaysDotDescription

    /// The tooltip of both dots: how icons are hidden, and why.
    public static func tooltip(for engine: EngineStatus) -> String {
        "Hiding with \(engine.kind.title). \(engine.reason)"
    }

    /// The menu the right click opens, in the order it is shown. (Menu items use title case.)
    public static let settingsItem = "Settings…"
    public static let commandBarItem = "Command Bar…"
    public static let focusModeItem = "Focus Mode"
    public static let refreshItem = "Refresh Menu Bar"
    public static let diagnosticsItem = "Diagnostics…"
    public static let quitItem = "Quit Mantel"
}
