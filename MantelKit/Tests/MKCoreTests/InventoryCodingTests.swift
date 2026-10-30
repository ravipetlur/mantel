import CoreGraphics
import Foundation
import MKCore
import Testing

/// What an inventory is saved as: the same text every time it is written, whichever process writes it.
@Suite("Inventory coding", .timeLimit(.minutes(1)))
struct InventoryCodingTests {
    /// Enough names that a set listing them in the order it likes has no real chance of listing them in order.
    private static let displays: Set<String> = ["display-h", "display-c", "display-f", "display-a", "display-g", "display-d", "display-b", "display-e"]
    private static let sorted = displays.sorted()

    private func item() -> MenuBarItem {
        MenuBarItem(id: ItemID(bundleID: "com.example.app", key: .identifier("main")), ownerBundleID: "com.example.app", appName: "App",
                    label: nil, frames: [:], overflowedOn: Self.displays, isMantel: false, isDot: true,
                    inferredOverflowOn: Self.displays, sharesFrameOn: Self.displays, reportedWidth: 24)
    }

    private func inventory() -> Inventory {
        Inventory(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), bars: [], items: [item()], chevrons: [:], reach: [], problems: [],
                  unansweredApps: ["com.example.z", "com.example.m", "com.example.a", "com.example.q", "com.example.c", "com.example.x", "com.example.b",
                                   "com.example.k"])
    }

    private func strings(_ json: Any?, _ key: String) -> [String]? {
        (json as? [String: Any])?[key] as? [String]
    }

    @Test func aReadSaidToHaveBeenCutKeepsEverythingElseItSays() {
        let read = Inventory(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), bars: [], items: [item()], chevrons: [:], reach: [],
                             problems: [], unansweredApps: ["com.example.a"], contestedApps: ["com.example.c"],
                             incompleteApps: ["com.example.b"], appProcesses: ["com.example.a": [41], "com.example.b": [42, 43]])
        let cut = read.markingAgentReadCut()
        #expect(cut.agentReadCut)
        #expect(cut.unansweredApps == ["com.example.a"])
        #expect(cut.contestedApps == ["com.example.c"])
        #expect(cut.incompleteApps == ["com.example.b"])
        #expect(cut.appProcesses == ["com.example.a": [41], "com.example.b": [42, 43]])
        #expect(cut.items == read.items)
    }

    @Test func setFieldsEncodeSorted() throws {
        let itemJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item()))
        for key in ["overflowedOn", "inferredOverflowOn", "sharesFrameOn"] {
            #expect(strings(itemJSON, key) == Self.sorted, "\(key) is in order")
        }

        let inventoryJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(inventory()))
        #expect(strings(inventoryJSON, "unansweredApps") == ["com.example.a", "com.example.b", "com.example.c", "com.example.k", "com.example.m",
                                                              "com.example.q", "com.example.x", "com.example.z"])
        let items = (inventoryJSON as? [String: Any])?["items"] as? [Any]
        #expect(strings(items?.first, "overflowedOn") == Self.sorted, "and so are those of the items inside it")
    }

    @Test func theSameInventoryEncodesToTheSameBytes() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(inventory())
        for _ in 0..<5 { #expect(try encoder.encode(inventory()) == first) }
    }

    @Test func whatWasWrittenReadsBack() throws {
        let original = inventory()
        let back = try JSONDecoder().decode(Inventory.self, from: JSONEncoder().encode(original))
        #expect(back == original)
        #expect(back.items.first?.overflowedOn == Self.displays)
    }

    @Test func theSlotsOfABarReadBackAndAnOlderInventoryHasNone() throws {
        let slots = ["display-a": [BarSlot(frame: CGRect(x: 10, y: 0, width: 30, height: 24), name: "one"),
                                   BarSlot(frame: CGRect(x: 50, y: 0, width: 30, height: 24), name: nil)]]
        let with = Inventory(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), bars: [], items: [], chevrons: [:], reach: [], problems: [],
                             barSlots: slots)
        let back = try JSONDecoder().decode(Inventory.self, from: JSONEncoder().encode(with))
        #expect(back.barSlots == slots)

        // One that has none writes none, and reads back as one that has none.
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(inventory())) as? [String: Any])
        #expect(json["barSlots"] == nil)
        #expect(try JSONDecoder().decode(Inventory.self, from: JSONEncoder().encode(inventory())).barSlots.isEmpty)
    }

    @Test func theSlotsAreNotWhatMakesAReadAnotherRead() {
        func read(_ name: String?) -> Inventory {
            Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: [], items: [], chevrons: [:], reach: [], problems: [],
                      barSlots: ["d": [BarSlot(frame: .zero, name: name)]])
        }
        #expect(read("a") == read(nil))
    }

    @Test func anItemWithNothingOptionalStillReadsBack() throws {
        let bare = MenuBarItem(id: .system("clock"), ownerBundleID: ItemID.systemBundleID, appName: nil, label: nil, frames: [:],
                               overflowedOn: [], isMantel: false)
        let back = try JSONDecoder().decode(MenuBarItem.self, from: JSONEncoder().encode(bare))
        #expect(back == bare)
    }

    @Test func anOwnItemsKindReadsBackAndAnOlderItemHasNone() throws {
        func ownItem(_ kind: OwnItemKind?, isDot: Bool = false) -> MenuBarItem {
            MenuBarItem(id: ItemID(bundleID: "com.example.mantel", key: .identifier("mantel.thing")), ownerBundleID: "com.example.mantel", appName: nil,
                        label: nil, frames: [:], overflowedOn: [], isMantel: true, isDot: isDot, ownKind: kind)
        }
        for kind in OwnItemKind.allCases {
            let item = ownItem(kind)
            let back = try JSONDecoder().decode(MenuBarItem.self, from: JSONEncoder().encode(item))
            #expect(back == item)
            #expect(back.ownKind == kind)
            // A dot is the two kinds that are dots, however the item was made.
            #expect(back.isDot == (kind == .hiddenDot || kind == .alwaysDot), "\(kind)")
        }
        #expect(ownItem(.hiddenDot).isDot)
        #expect(!ownItem(.spacer).isDot)

        // An item with no kind doesn't write one, and one saved before kinds were kept reads with none and keeps its `isDot`.
        let none = ownItem(nil, isDot: true)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(none)) as? [String: Any])
        #expect(object["ownKind"] == nil)
        object["ownKind"] = nil
        let older = try JSONDecoder().decode(MenuBarItem.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.ownKind == nil)
        #expect(older.isDot)
        #expect(older == none)

        let written = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ownItem(.divider))) as? [String: Any])
        #expect(written["ownKind"] as? String == "divider")
        #expect(OwnItemKind.allCases.map(\.rawValue) == ["hiddenDot", "alwaysDot", "divider", "spacer", "group"])
    }

    @Test func isDotFollowsTheKindBothWays() throws {
        func make(isDot: Bool, kind: OwnItemKind?) -> MenuBarItem {
            MenuBarItem(id: ItemID(bundleID: "com.example.mantel", key: .identifier("mantel.thing")), ownerBundleID: "com.example.mantel", appName: nil,
                        label: nil, frames: [:], overflowedOn: [], isMantel: true, isDot: isDot, ownKind: kind)
        }
        // A kind that says what the item is decides: a spacer, the divider or a group's icon is never a dot, whatever it was given.
        for kind in OwnItemKind.allCases {
            for given in [false, true] {
                #expect(make(isDot: given, kind: kind).isDot == (kind == .hiddenDot || kind == .alwaysDot), "\(kind), given \(given)")
            }
        }
        // With no kind it is as it was given, so an item that only says it is a dot stays one.
        #expect(make(isDot: true, kind: nil).isDot)
        #expect(!make(isDot: false, kind: nil).isDot)

        // And so is one that is read from a file.
        func decoded(_ json: String) throws -> MenuBarItem {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(make(isDot: false, kind: nil))) as? [String: Any])
            let extra = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            object.merge(extra) { _, new in new }
            return try JSONDecoder().decode(MenuBarItem.self, from: JSONSerialization.data(withJSONObject: object))
        }
        #expect(try !decoded(#"{"isDot":true,"ownKind":"spacer"}"#).isDot)
        #expect(try !decoded(#"{"isDot":true,"ownKind":"divider"}"#).isDot)
        #expect(try !decoded(#"{"isDot":true,"ownKind":"group"}"#).isDot)
        #expect(try decoded(#"{"isDot":false,"ownKind":"hiddenDot"}"#).isDot)
        #expect(try decoded(#"{"isDot":false,"ownKind":"alwaysDot"}"#).isDot)
        #expect(try decoded(#"{"isDot":true}"#).isDot, "saved before kinds were kept: as it was")
        #expect(try !decoded(#"{"isDot":false}"#).isDot)
        // A kind this version doesn't know is none, and the item is as it was saved.
        let unknown = try decoded(#"{"isDot":true,"ownKind":"sparkle"}"#)
        #expect(unknown.ownKind == nil)
        #expect(unknown.isDot)
    }

    @Test func contestedAppsRoundTripAndAreOptional() throws {
        let original = Inventory(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), bars: [], items: [item()], chevrons: [:], reach: [],
                                 problems: [], contestedApps: ["com.example.z", "com.example.a", "com.example.m"])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Inventory.self, from: data) == original)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["contestedApps"] as? [String] == ["com.example.a", "com.example.m", "com.example.z"], "written in order")

        // One saved before the field was kept has none.
        var older = json
        older.removeValue(forKey: "contestedApps")
        let decoded = try JSONDecoder().decode(Inventory.self, from: JSONSerialization.data(withJSONObject: older))
        #expect(decoded.contestedApps.isEmpty)
    }
}
