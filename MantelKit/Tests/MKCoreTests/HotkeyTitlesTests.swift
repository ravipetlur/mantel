import Foundation
import Testing

@testable import MKCore

@Suite("Hotkey titles", .timeLimit(.minutes(1)))
struct HotkeyTitlesTests {
    private let weather = ItemID(bundleID: "com.example.weather", key: .identifier("weather.temp"))

    @Test func actionTitles() {
        for action in HotkeyAction.all {
            #expect(HotkeyTitles.title(for: action.id, iconName: { _ in nil }) == action.title)
        }
        // An action's title doesn't ask for an icon's name.
        #expect(HotkeyTitles.title(for: .secondBar, iconName: { _ in "Never asked" }) == "Show the second bar")
    }

    @Test func iconClashNamesTheIcon() {
        let id = HotkeyID.icon(weather)
        #expect(HotkeyTitles.title(for: id, iconName: { $0 == weather ? "Weather" : nil }) == "Weather (icon)")
        // The warning under another field says it that way, and never by the ID.
        let combo = KeyCombo(keyCode: 40, modifiers: [.command, .option])
        let clashes = ClashDetector.clashes(for: combo, assigning: .openSettings, mantel: [id: combo], system: [])
        let message = clashes.map { $0.message(actionTitle: { HotkeyTitles.title(for: $0, iconName: { _ in "Weather" }) }) }
        #expect(message == ["Already used by Mantel: Weather (icon)"])
        #expect(!message.joined().contains("icon:"))
    }

    @Test func unknownIDIsNil() {
        #expect(HotkeyTitles.title(for: HotkeyID(rawValue: "from-a-newer-mantel"), iconName: { _ in "Weather" }) == nil)
        // An icon the caller has no name for, and one that says `icon:` and then something that isn't an icon.
        #expect(HotkeyTitles.title(for: .icon(weather), iconName: { _ in nil }) == nil)
        #expect(HotkeyTitles.title(for: HotkeyID(rawValue: "icon:"), iconName: { _ in "Weather" }) == nil)
    }
}

@Suite("Icon hotkey choices", .timeLimit(.minutes(1)))
struct IconHotkeyChoicesTests {
    @Test func optionClickIsLeftOutWhileItCannotBePosted() {
        #expect(IconHotkeyAction.choices(keeping: nil, optionWorks: false) == [.show, .click(.left), .click(.right)])
        #expect(IconHotkeyAction.choices(keeping: .click(.right), optionWorks: false) == [.show, .click(.left), .click(.right)])
        #expect(IconHotkeyAction.choices(keeping: nil, optionWorks: true) == IconHotkeyAction.allChoices)
    }

    @Test func aBindingThatHasOptionClickKeepsIt() {
        let kept = IconHotkeyAction.choices(keeping: .click(.option), optionWorks: false)
        #expect(kept == IconHotkeyAction.allChoices)
        #expect(IconHotkeyAction.allChoices.map(\.title) == ["Show", "Show and click", "Show and right-click", "Show and option-click"])
    }
}
