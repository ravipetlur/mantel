import Foundation

extension IconHotkeyAction {
    /// Every action an icon's hotkey can do, in the order the picker lists them.
    public static let allChoices: [IconHotkeyAction] = [.show, .click(.left), .click(.right), .click(.option)]

    /// The actions the picker offers for an icon whose hotkey does `current` (nil for one that has none yet).
    ///
    /// An option click can't be posted on this Mac (`optionWorks` false: it arrives as a plain left click), so it isn't offered. An icon that
    /// already has it keeps it, and the picker still shows it, so that what the icon does isn't hidden from the person.
    public static func choices(keeping current: IconHotkeyAction?, optionWorks: Bool) -> [IconHotkeyAction] {
        allChoices.filter { choice in
            if case .click(.option) = choice { return optionWorks || current == choice }
            return true
        }
    }
}
