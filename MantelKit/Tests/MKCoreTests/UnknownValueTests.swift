import Foundation
import MKTestSupport
import Synchronization
import Testing

@testable import MKCore

/// A value that this version doesn't know (a case of an enum that a later version added) is read as missing, so one such value doesn't
/// fail the value that holds it, or the file: the default is used, the rest is read as it is, and the log says which key, once.
@Suite("Unknown enum values", .timeLimit(.minutes(1)))
struct UnknownValueTests {
    /// What `json` decodes to, and what was logged while it did.
    private func decode<T: Decodable & Sendable>(_ type: T.Type, _ json: String) async -> (value: T?, lines: [String]) {
        let decoded = Mutex<T?>(nil)
        let lines = await LogCapture.lines {
            decoded.withLock { $0 = try? JSONDecoder().decode(T.self, from: Data(json.utf8)) }
        }
        return (decoded.withLock { $0 }, lines)
    }

    /// The log lines that say the value of `key` wasn't known.
    private func said(_ lines: [String], of key: String) -> [String] {
        lines.filter { $0.contains("the value of \(key) isn't one this version knows, so its default is used") }
    }

    @Test func anUnknownDotsPlacementIsTheDefault() async {
        let (value, lines) = await decode(LayoutSettings.self, #"{"dotsPlacement":"bogus","showAllWhileCommandDragging":true}"#)
        #expect(value == LayoutSettings(dotsPlacement: .betweenSections, showAllWhileCommandDragging: true))
        #expect(said(lines, of: "dotsPlacement").count == 1, "\(lines)")
        #expect(!lines.contains { $0.contains("bogus") }, "what the file held is not in the log")
    }

    @Test func anUnknownSecondBarOpeningIsTheDefault() async {
        let (value, lines) = await decode(SecondBarSettings.self, #"{"opens":"bogus","position":"rightAligned"}"#)
        #expect(value?.opens == .whenNoRoom)
        #expect(value?.position == .rightAligned)
        #expect(said(lines, of: "opens").count == 1, "\(lines)")
        #expect(said(lines, of: "position").isEmpty)
        #expect(!lines.contains { $0.contains("bogus") })
    }

    @Test func anUnknownSecondBarPositionIsTheDefault() async {
        let (value, lines) = await decode(SecondBarSettings.self, #"{"opens":"always","position":"bogus"}"#)
        #expect(value?.opens == .always)
        #expect(value?.position == .underDot)
        #expect(said(lines, of: "position").count == 1, "\(lines)")
        #expect(said(lines, of: "opens").isEmpty)
        #expect(!lines.contains { $0.contains("bogus") })
    }

    @Test func anUnknownPanelAppearanceIsTheDefault() async {
        let (value, lines) = await decode(PanelStyle.self, #"{"appearance":"bogus","shadow":false,"background":{"kind":"solid","color":{"red":1}}}"#)
        #expect(value?.appearance == .matchMenuBar)
        #expect(value?.shadow == false)
        #expect(value?.background == .solid(RGBAColor(red: 1, green: 0, blue: 0)))
        #expect(said(lines, of: "appearance").count == 1, "\(lines)")
        #expect(!lines.contains { $0.contains("bogus") })
    }

    @Test func anUnknownMaterialThicknessIsTheDefault() async {
        // As an unknown kind of background is the menu bar's look, an unknown thickness is the regular one.
        let (value, lines) = await decode(PanelStyle.self, #"{"background":{"kind":"material","thickness":"bogus"},"shadow":false}"#)
        #expect(value?.background == .material(.regular))
        #expect(value?.shadow == false)
        #expect(said(lines, of: "thickness").count == 1, "\(lines)")
        #expect(!lines.contains { $0.contains("bogus") })
    }

    @Test func anUnknownAlwaysDotVisibilityIsTheDefault() async {
        let (value, lines) = await decode(DotSettings.self, #"{"alwaysDot":"bogus","hideBothDots":true,"style":{"kind":"chevrons"}}"#)
        #expect(value == DotSettings(style: .chevrons, alwaysDot: .whenNeeded, hideBothDots: true, showsDivider: false))
        #expect(said(lines, of: "alwaysDot").count == 1, "\(lines)")
        #expect(!lines.contains { $0.contains("bogus") })
    }

    @Test func anUnknownOwnItemKindIsNone() async throws {
        let item = MenuBarItem(id: ItemID(bundleID: "com.example.mantel", key: .identifier("mantel.thing")), ownerBundleID: "com.example.mantel",
                               appName: "Mantel", label: nil, frames: [:], overflowedOn: [], isMantel: true, isDot: true)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        object["ownKind"] = "bogus"
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let (value, lines) = await decode(MenuBarItem.self, json)
        #expect(value == item, "the item is read, with no kind, and as it was saved")
        #expect(value?.ownKind == nil)
        #expect(said(lines, of: "ownKind").count == 1, "\(lines)")
        #expect(!lines.contains { $0.contains("bogus") })
    }

    @Test func anUnknownValueDoesNotFailTheInventory() async throws {
        let item = MenuBarItem(id: ItemID(bundleID: "com.example.mantel", key: .identifier("mantel.thing")), ownerBundleID: "com.example.mantel",
                               appName: nil, label: nil, frames: [:], overflowedOn: [], isMantel: true, ownKind: .spacer)
        let inventory = Inventory(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), bars: [], items: [item, item], chevrons: [:], reach: [],
                                  problems: [])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(inventory)) as? [String: Any])
        var items = try #require(object["items"] as? [[String: Any]])
        items[0]["ownKind"] = "bogus"
        object["items"] = items
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let (value, _) = await decode(Inventory.self, json)
        #expect(value?.items.map(\.ownKind) == [nil, .spacer])
    }
}
