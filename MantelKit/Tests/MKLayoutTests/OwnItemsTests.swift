import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKLayout

@Suite("Own items", .timeLimit(.minutes(1)))
struct OwnItemsTests {
    private static func isEightHex(_ text: String) -> Bool {
        text.count == 8 && text.allSatisfy { "0123456789abcdef".contains($0) }
    }

    @Test func idsAreEightHex() {
        var spacers: Set<String> = []
        var groups: Set<String> = []
        for _ in 0..<300 {
            let spacer = SpacerID.make().rawValue
            let group = GroupID.make().rawValue
            #expect(Self.isEightHex(spacer), "\(spacer)")
            #expect(Self.isEightHex(group), "\(group)")
            spacers.insert(spacer)
            groups.insert(group)
        }
        // They are random: 300 of 4 billion don't repeat, bar a freak.
        #expect(spacers.count >= 298)
        #expect(groups.count >= 298)
    }

    @Test func idsNeverReserved() {
        // The wide spacer's invisible items go by `mantel.spacer.divider`, `mantel.spacer.divider.2` … and `mantel.spacer.always`.
        // An id is hexadecimal, and none of those words is, so an id is never one.
        let reserved: Set<String> = ["divider", "always", "divider.2", "divider.10"]
        for _ in 0..<300 {
            #expect(!reserved.contains(SpacerID.make().rawValue))
            #expect(!reserved.contains(GroupID.make().rawValue))
        }
        #expect(!reserved.contains { Self.isEightHex($0) })

        // And those names are not a spacer of the person's: they are no kind of own item at all.
        for name in ["mantel.spacer.divider", "mantel.spacer.divider.2", "mantel.spacer.divider.3", "mantel.spacer.always"] {
            #expect(OwnItems.kind(name: name, description: nil) == nil, "\(name)")
            #expect(!OwnItems.isOwn(ItemID(bundleID: OwnItems.owner, key: .identifier(name))), "\(name)")
            #expect(OwnItems.autosaveName(of: ItemID(bundleID: OwnItems.owner, key: .identifier(name))) == nil, "\(name)")
        }
        // A spacer that is made is one.
        let made = SpacerID.make()
        #expect(OwnItems.kind(name: "mantel.spacer.\(made.rawValue)", description: nil) == .spacer)
    }

    @Test func itemIDsUseFixedOwner() throws {
        #expect(OwnItems.owner == "mantel")
        let spacer = SpacerID(rawValue: "1a2b3c4d")
        let group = GroupID(rawValue: "5e6f7a8b")
        #expect(OwnItems.itemID(spacer).bundleID == "mantel")
        #expect(OwnItems.itemID(spacer).string == "mantel::mantel.spacer.1a2b3c4d")
        #expect(OwnItems.itemID(group).bundleID == "mantel")
        #expect(OwnItems.itemID(group).string == "mantel::mantel.group.5e6f7a8b")
        // The text names the same item again, so a layout travels with it.
        #expect(ItemID(string: OwnItems.itemID(spacer).string) == OwnItems.itemID(spacer))
        #expect(ItemID(string: OwnItems.itemID(group).string) == OwnItems.itemID(group))
        #expect(OwnItems.itemID(spacer) != OwnItems.itemID(SpacerID(rawValue: "1a2b3c4e")))
        // A spacer and a group made with the same letters are two items.
        #expect(OwnItems.itemID(SpacerID(rawValue: "abcdef01")) != OwnItems.itemID(GroupID(rawValue: "abcdef01")))
    }

    @Test func autosaveNameRoundTrip() {
        let spacer = SpacerID.make()
        let group = GroupID.make()
        #expect(OwnItems.autosaveName(of: OwnItems.itemID(spacer)) == "mantel.spacer.\(spacer.rawValue)")
        #expect(OwnItems.autosaveName(of: OwnItems.itemID(group)) == "mantel.group.\(group.rawValue)")
        #expect(OwnItems.spacerID(of: OwnItems.itemID(spacer)) == spacer)
        #expect(OwnItems.groupID(of: OwnItems.itemID(group)) == group)
        #expect(OwnItems.spacerID(of: OwnItems.itemID(group)) == nil)
        #expect(OwnItems.groupID(of: OwnItems.itemID(spacer)) == nil)
        #expect(OwnItems.isOwn(OwnItems.itemID(spacer)))
        #expect(OwnItems.isOwn(OwnItems.itemID(group)))

        // The dots and the divider are own items with the names they keep their places under.
        for name in [OwnItems.hiddenDotName, OwnItems.alwaysDotName, OwnItems.dividerName] {
            let item = ItemID(bundleID: OwnItems.owner, key: .identifier(name))
            #expect(OwnItems.autosaveName(of: item) == name)
            #expect(OwnItems.isOwn(item))
        }

        // Nothing else is: another owner, a name that is none of the kinds', an index, a system item.
        let notOwn = [
            ItemID(bundleID: "com.example.app", key: .identifier("mantel.spacer.\(spacer.rawValue)")),
            ItemID(bundleID: OwnItems.owner, key: .identifier("main")),
            ItemID(bundleID: OwnItems.owner, key: .index(0)),
            ItemID(bundleID: "com.example.app", key: .identifier("main")),
            ItemID(bundleID: OwnItems.owner, key: .identifier("mantel.spacer.")),
            ItemID(bundleID: OwnItems.owner, key: .identifier("mantel.group.")),
            .system("clock"),
        ]
        for item in notOwn {
            #expect(OwnItems.autosaveName(of: item) == nil, "\(item)")
            #expect(!OwnItems.isOwn(item), "\(item)")
        }
    }

    private static func name(of kind: OwnItemKind) -> String {
        switch kind {
        case .hiddenDot: OwnItems.hiddenDotName
        case .alwaysDot: OwnItems.alwaysDotName
        case .divider: OwnItems.dividerName
        case .spacer: "mantel.spacer.1a2b3c4d"
        case .group: "mantel.group.5e6f7a8b"
        }
    }

    private static func description(of kind: OwnItemKind) -> String {
        switch kind {
        case .hiddenDot: OwnItems.hiddenDotDescription
        case .alwaysDot: OwnItems.alwaysDotDescription
        case .divider: OwnItems.dividerDescription
        case .spacer: OwnItems.spacerDescription
        case .group: OwnItems.groupDescription(title: "Chat")
        }
    }

    @Test(arguments: OwnItemKind.allCases)
    func kindFromNameOrDescription(kind: OwnItemKind) {
        let name = Self.name(of: kind)
        let description = Self.description(of: kind)
        #expect(OwnItems.kind(name: name, description: nil) == kind, "by its name")
        #expect(OwnItems.kind(name: nil, description: description) == kind, "by its description")
        #expect(OwnItems.kind(name: name, description: description) == kind, "by both")
        #expect(OwnItems.kind(name: "some.other.name", description: description) == kind, "a name that says nothing leaves it to the description")
        // The name decides when it says.
        let another = OwnItemKind.allCases.first { $0 != kind && $0 != .group } ?? .divider
        #expect(OwnItems.kind(name: name, description: Self.description(of: another)) == kind)
        // What is neither is nothing.
        #expect(OwnItems.kind(name: "some.other.name", description: "Something else") == nil)
    }

    @Test func theWordsOfOwnItemsAreTheOnesInTheMenuBar() {
        #expect(OwnItems.hiddenDotName == "mantel.dot.hidden")
        #expect(OwnItems.alwaysDotName == "mantel.dot.always")
        #expect(OwnItems.dividerName == "mantel.divider.main")
        #expect(OwnItems.hiddenDotDescription == "Show hidden icons")
        #expect(OwnItems.alwaysDotDescription == "Show all icons")
        #expect(OwnItems.dividerDescription == "Divider")
        #expect(OwnItems.spacerDescription == "Spacer")
        #expect(OwnItems.groupDescription(title: "Chat") == "Chat group")
        #expect(OwnItems.groupDescription(title: nil) == "Icon group")
        #expect(OwnItems.groupDescription(title: "") == "Icon group")
        #expect(OwnItems.groupDescription(title: "   ") == "Icon group")

        // A group is told by its description whatever its title says, even a title that is another own item's description.
        for title in [nil, "Chat", "Show all icons", "Spacer", "Divider", "Two words"] {
            #expect(OwnItems.kind(name: nil, description: OwnItems.groupDescription(title: title)) == .group, "\(title ?? "no title")")
        }
        #expect(OwnItems.kind(name: nil, description: "Icon group") == .group)
        // Names with no id are none, and a description that merely has the words in it is none.
        #expect(OwnItems.kind(name: "mantel.spacer.", description: nil) == nil)
        #expect(OwnItems.kind(name: "mantel.group.", description: nil) == nil)
        #expect(OwnItems.kind(name: nil, description: "Groups") == nil)
        #expect(OwnItems.kind(name: nil, description: "Spacers") == nil)
        #expect(OwnItems.kind(name: nil, description: "") == nil)
        #expect(OwnItems.kind(name: nil, description: nil) == nil)
    }

    @Test func idDictionariesEncodeAsObjects() throws {
        let spacer = LayoutSpacer(id: SpacerID(rawValue: "1a2b3c4d"), width: 20, label: .emoji("🙂"))
        let group = IconGroup(id: GroupID(rawValue: "5e6f7a8b"), title: "Chat", look: .emoji("💬"), opensOnHover: true, members: ["com.example.a"])

        let spacers = try JSONSerialization.jsonObject(with: JSONEncoder().encode([spacer.id: spacer]))
        let spacerObject = try #require(spacers as? [String: Any])
        #expect(Array(spacerObject.keys) == ["1a2b3c4d"])
        #expect((spacerObject["1a2b3c4d"] as? [String: Any])?["width"] as? Int == 20)

        let groups = try JSONSerialization.jsonObject(with: JSONEncoder().encode([group.id: group]))
        let groupObject = try #require(groups as? [String: Any])
        #expect(Array(groupObject.keys) == ["5e6f7a8b"])
        #expect((groupObject["5e6f7a8b"] as? [String: Any])?["title"] as? String == "Chat")

        // The appearance of a bar (images are kept per appearance) is written the same way.
        let appearances = try JSONSerialization.jsonObject(with: JSONEncoder().encode([BarAppearance.light: 1, .dark: 2]))
        #expect(appearances as? [String: Int] == ["light": 1, "dark": 2])

        // And they read back, from the objects and from lists of the IDs themselves.
        #expect(try JSONDecoder().decode([SpacerID: LayoutSpacer].self, from: JSONEncoder().encode([spacer.id: spacer])) == [spacer.id: spacer])
        #expect(try JSONDecoder().decode([GroupID: IconGroup].self, from: JSONEncoder().encode([group.id: group])) == [group.id: group])
        #expect(try JSONDecoder().decode([BarAppearance: Int].self, from: Data(#"{"dark":7}"#.utf8)) == [.dark: 7])
        let ids = try JSONEncoder().encode([spacer.id, SpacerID(rawValue: "0000ffff")])
        #expect(String(decoding: ids, as: UTF8.self) == #"["1a2b3c4d","0000ffff"]"#, "an ID alone is a plain string")
        #expect(try JSONDecoder().decode([SpacerID].self, from: ids).map(\.rawValue) == ["1a2b3c4d", "0000ffff"])
        #expect(try JSONDecoder().decode([GroupID].self, from: Data(#"["5e6f7a8b"]"#.utf8)) == [group.id])
    }

    // MARK: The values of own items

    @Test func spacerWidthsAreKeptInRange() throws {
        #expect(LayoutSpacer.defaultWidth == 12)
        #expect(LayoutSpacer.widthRange == 4...200)
        #expect(LayoutSpacer(id: SpacerID(rawValue: "a")).width == 12)
        // The initializer brings a width into range too, and so does a width that is given later to the layout (`SectionModel`).
        #expect(LayoutSpacer(id: SpacerID(rawValue: "a"), width: 4).width == 4)
        #expect(LayoutSpacer(id: SpacerID(rawValue: "a"), width: 200).width == 200)
        #expect(LayoutSpacer(id: SpacerID(rawValue: "a"), width: 1).width == 4)
        #expect(LayoutSpacer(id: SpacerID(rawValue: "a"), width: -9).width == 4)
        #expect(LayoutSpacer(id: SpacerID(rawValue: "a"), width: 999).width == 200)

        func width(_ text: String) throws -> Int {
            try JSONDecoder().decode(LayoutSpacer.self, from: Data(#"{"id":"a1b2c3d4",\#(text)}"#.utf8)).width
        }
        #expect(try width(#""width":4"#) == 4)
        #expect(try width(#""width":200"#) == 200)
        #expect(try width(#""width":3"#) == 4)
        #expect(try width(#""width":-5"#) == 4)
        #expect(try width(#""width":201"#) == 200)
        #expect(try width(#""width":99999"#) == 200)
        #expect(try width(#""other":1"#) == 12, "a width that is missing is a new spacer's")
        #expect(try JSONDecoder().decode(LayoutSpacer.self, from: Data(#"{"id":"a1b2c3d4"}"#.utf8))
            == LayoutSpacer(id: SpacerID(rawValue: "a1b2c3d4"), width: 12, label: nil))
    }

    @Test func labelsLooksAndGroupsRoundTrip() throws {
        let labels: [OwnItemLabel?] = [nil, .text("Work"), .emoji("🙂"), .symbol("star.fill")]
        for label in labels {
            let spacer = LayoutSpacer(id: SpacerID(rawValue: "a1b2c3d4"), width: 30, label: label)
            #expect(try JSONDecoder().decode(LayoutSpacer.self, from: JSONEncoder().encode(spacer)) == spacer, "\(String(describing: label))")
        }
        let looks: [GroupLook] = [.symbol("star"), .emoji("💬"), .image(fileName: "chat.png"), .standard]
        for look in looks {
            let group = IconGroup(id: GroupID(rawValue: "e5f6a7b8"), title: "Chat", look: look, opensOnHover: true, members: ["com.example.a", "com.example.b"])
            #expect(try JSONDecoder().decode(IconGroup.self, from: JSONEncoder().encode(group)) == group, "\(look)")
        }

        // A group that is given nothing is the standard one: a grid symbol, opened by a click, with no members.
        let plain = IconGroup(id: GroupID(rawValue: "e5f6a7b8"))
        #expect(plain.look == .symbol("square.grid.2x2"))
        #expect(!plain.opensOnHover)
        #expect(plain.members.isEmpty)
        #expect(plain.title == nil)
        #expect(try JSONDecoder().decode(IconGroup.self, from: Data(#"{"id":"e5f6a7b8"}"#.utf8)) == plain)
    }

    @Test func aLookOrALabelThisVersionDoesNotKnowIsLeftOut() async throws {
        let look = #"{"id":"e5f6a7b8","title":"Chat","look":{"kind":"hologram","value":"x"},"members":["com.example.a"]}"#
        let label = #"{"id":"a1b2c3d4","width":30,"label":{"kind":"hologram","value":"x"}}"#
        let group = Mutex<IconGroup?>(nil)
        let spacer = Mutex<LayoutSpacer?>(nil)
        let lines = await LogCapture.lines {
            group.withLock { $0 = try? JSONDecoder().decode(IconGroup.self, from: Data(look.utf8)) }
            spacer.withLock { $0 = try? JSONDecoder().decode(LayoutSpacer.self, from: Data(label.utf8)) }
        }
        #expect(group.withLock { $0 } == IconGroup(id: GroupID(rawValue: "e5f6a7b8"), title: "Chat", look: .standard, opensOnHover: false,
                                                  members: ["com.example.a"]))
        #expect(spacer.withLock { $0 } == LayoutSpacer(id: SpacerID(rawValue: "a1b2c3d4"), width: 30, label: nil))
        #expect(lines.filter { $0.contains("a group's look this version doesn't know") }.count == 1)
        #expect(lines.filter { $0.contains("a spacer's label this version doesn't know") }.count == 1)
        #expect(!lines.contains { $0.contains("hologram") }, "what the file held is not in the log")
    }

    @Test func aReservedNameHasNoKindWhateverItsDescriptionSays() {
        // The wide spacer's invisible items are Mantel's, and none of the own items: the name says so, and the description isn't asked.
        for name in ["mantel.spacer.divider", "mantel.spacer.divider.2", "mantel.spacer.divider.17", "mantel.spacer.always"] {
            for description in [nil, OwnItems.spacerDescription, OwnItems.dividerDescription, OwnItems.hiddenDotDescription,
                                OwnItems.alwaysDotDescription, OwnItems.groupDescription(title: nil)] {
                #expect(OwnItems.kind(name: name, description: description) == nil, "\(name) / \(description ?? "no description")")
            }
        }
        // So does a name in the spacer's or the group's family that carries no id, or an id that can't be one.
        for name in ["mantel.spacer.", "mantel.group.", "mantel.group.always", "mantel.group.divider", "mantel.group.divider.3"] {
            #expect(OwnItems.kind(name: name, description: OwnItems.spacerDescription) == nil, "\(name)")
        }
        // A name that is none of Mantel's says nothing, and the description decides, as ever.
        #expect(OwnItems.kind(name: "mantel.spacers.divider", description: OwnItems.spacerDescription) == .spacer)
        #expect(OwnItems.kind(name: "other", description: OwnItems.spacerDescription) == .spacer)
        #expect(OwnItems.kind(name: "mantel.spacer.1a2b3c4d", description: OwnItems.hiddenDotDescription) == .spacer, "the name decides")
    }

    @Test func anIdThatCannotBeAnOwnItemsIsNoOwnItem() {
        // Any string makes an ID, but a spacer or group with an empty or a reserved one has no own item's name.
        for raw in ["", "always", "divider", "divider.2"] {
            let spacer = SpacerID(rawValue: raw)
            let group = GroupID(rawValue: raw)
            #expect(!OwnItems.isOwn(OwnItems.itemID(spacer)), "\"\(raw)\"")
            #expect(!OwnItems.isOwn(OwnItems.itemID(group)), "\"\(raw)\"")
            #expect(OwnItems.autosaveName(of: OwnItems.itemID(spacer)) == nil, "\"\(raw)\"")
            #expect(OwnItems.spacerID(of: OwnItems.itemID(spacer)) == nil, "\"\(raw)\"")
            #expect(OwnItems.groupID(of: OwnItems.itemID(group)) == nil, "\"\(raw)\"")
            #expect(!OwnItems.isUsable(spacer) && !OwnItems.isUsable(group), "\"\(raw)\"")
        }
        // The ones that are made, and odd ones that are fine, are.
        for raw in [SpacerID.make().rawValue, "0", "s1", "Always", "divider-x"] {
            #expect(OwnItems.isOwn(OwnItems.itemID(SpacerID(rawValue: raw))), "\(raw)")
            #expect(OwnItems.isOwn(OwnItems.itemID(GroupID(rawValue: raw))), "\(raw)")
            #expect(OwnItems.isUsable(SpacerID(rawValue: raw)) && OwnItems.isUsable(GroupID(rawValue: raw)), "\(raw)")
        }
    }
}
