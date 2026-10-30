import Foundation
import MKCore
import Testing

@Suite("Hotkey IDs of icons", .timeLimit(.minutes(1)))
struct HotkeyIDTests {
    private let items: [ItemID] = [
        ItemID(bundleID: "com.example.weather", key: .identifier("weather.temp")),
        ItemID(bundleID: "com.example.sync", key: .index(2)),
        .system("wifi"),
        // An identifier that holds colons and a hash.
        ItemID(bundleID: "com.example.app", key: .identifier("a::b:c#3")),
    ]

    @Test func iconIDRoundTrip() throws {
        for item in items {
            let id = HotkeyID.icon(item)
            #expect(id.rawValue == "icon:" + item.string)
            #expect(id.iconItem == item, "\(item.string)")
            // A hotkey is kept under its raw value, and an icon's survives the file.
            let data = try JSONEncoder().encode([id: 7])
            #expect(try JSONDecoder().decode([HotkeyID: Int].self, from: data) == [id: 7])
            #expect(try JSONDecoder().decode([HotkeyID: Int].self, from: data).keys.first?.iconItem == item)
        }
        #expect(HotkeyID.icon(items[0]).rawValue == "icon:com.example.weather::weather.temp")
        #expect(HotkeyID.icon(items[1]).rawValue == "icon:com.example.sync#2")
        #expect(HotkeyID.icon(items[2]).rawValue == "icon:system:wifi")
        // Read from the text of a file.
        #expect(HotkeyID(rawValue: "icon:com.example.sync#2").iconItem == items[1])
        // Different icons are different hotkeys.
        #expect(Set(items.map(HotkeyID.icon)).count == items.count)
    }

    @Test func nonIconHasNoItem() {
        let others: [HotkeyID] = [.openSettings, .showHidden, .showAll, .focusMode, .secondBar, .mantelMenu]
        for id in others {
            #expect(id.iconItem == nil, "\(id.rawValue)")
        }
        // Nothing after the prefix, or something that isn't the text of an icon, or the prefix somewhere else, is no icon's.
        for raw in ["icon:", "icon:garbage", "icon:com.example.app::", "icon:#3", "Icon:com.example.app#1", " icon:com.example.app#1",
                    "x-icon:com.example.app#1", "icons:com.example.app#1", ""] {
            #expect(HotkeyID(rawValue: raw).iconItem == nil, "\(raw)")
        }
    }
}
