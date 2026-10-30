import Foundation
import Testing

@testable import MKCore

@Suite("Hotkey titles", .timeLimit(.minutes(1)))
struct HotkeyTitlesTests {
    private let weather = ItemID(bundleID: "com.example.weather", key: .identifier("weather.temp"))

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
