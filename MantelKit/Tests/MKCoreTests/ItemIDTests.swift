import Foundation
import Testing

@testable import MKCore

@Suite("Item ID", .timeLimit(.minutes(1)))
struct ItemIDTests {
    private func roundTrip(_ id: ItemID) {
        #expect(ItemID(string: id.string) == id, "\(id.string)")
    }

    @Test func identifierRoundTrip() {
        let id = ItemID(bundleID: "com.example.weather", key: .identifier("weather.temp"))
        #expect(id.string == "com.example.weather::weather.temp")
        #expect(id.description == id.string)
        #expect(!id.isSystem)
        roundTrip(id)
        #expect(ItemID(string: "com.example.weather::weather.temp")?.key == .identifier("weather.temp"))
    }

    @Test func identifierWithColonsRoundTrips() {
        // The first "::" splits the app from the name, and the name may hold any colons, a hash and digits.
        for name in ["a:b", "a::b", "a:::b", ":lead", "trail:", "Item-0#3", "x::y::z", "with space", "日本語"] {
            roundTrip(ItemID(bundleID: "com.example.app", key: .identifier(name)))
        }
        #expect(ItemID(string: "com.example.app::a::b")?.key == .identifier("a::b"))
    }

    @Test func indexRoundTrip() {
        let id = ItemID(bundleID: "com.example.sync", key: .index(2))
        #expect(id.string == "com.example.sync#2")
        roundTrip(id)
        roundTrip(ItemID(bundleID: "com.example.sync", key: .index(0)))
        // A name that looks like an index is still a name, because "::" comes first.
        #expect(ItemID(string: "com.example.sync::x#2")?.key == .identifier("x#2"))
    }

    @Test func systemRoundTrip() {
        let id = ItemID.system("clock")
        #expect(id.string == "system:clock")
        #expect(id.bundleID == ItemID.systemBundleID)
        #expect(id.isSystem)
        roundTrip(id)
        #expect(ItemID(string: "system:controlcenter") == ItemID.system("controlcenter"))
        // Whatever bundle ID is given with a system key, a system item belongs to the system.
        #expect(ItemID(bundleID: "com.example.other", key: .system(module: "clock")) == ItemID.system("clock"))
    }

    @Test func codableIsTheStringForm() throws {
        let ids = [ItemID(bundleID: "com.example.a", key: .identifier("x")), ItemID(bundleID: "com.example.a", key: .index(1)), .system("wifi")]
        let data = try JSONEncoder().encode(ids)
        #expect(String(decoding: data, as: UTF8.self) == #"["com.example.a::x","com.example.a#1","system:wifi"]"#)
        #expect(try JSONDecoder().decode([ItemID].self, from: data) == ids)

        // As part of a bigger value, and as the key of a list.
        struct Holder: Codable, Equatable { let id: ItemID }
        let holder = Holder(id: ids[0])
        #expect(String(decoding: try JSONEncoder().encode(holder), as: UTF8.self) == #"{"id":"com.example.a::x"}"#)
        #expect(try JSONDecoder().decode(Holder.self, from: JSONEncoder().encode(holder)) == holder)
    }

    @Test func unparseableStringFailsToDecode() {
        for bad in ["", "plain", "system:", "::x", "com.example.a::", "#3", "com.example.a#", "com.example.a#x", "com.example.a#-1", "com.example.a#1 "] {
            #expect(ItemID(string: bad) == nil, "\(bad)")
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(ItemID.self, from: JSONEncoder().encode(bad)) }
        }
    }

    @Test func generatedAppKitNamesAreNotIdentity() {
        // AppKit's made-up names change from one launch to the next.
        #expect(ItemID.usableIdentifier("_NS:574") == nil)
        #expect(ItemID.usableIdentifier("_NS:93") == nil)
        #expect(ItemID.usableIdentifier(nil) == nil)
        #expect(ItemID.usableIdentifier("") == nil)
        #expect(ItemID.usableIdentifier("su_Main Menu") == "su_Main Menu")
        #expect(ItemID.usableIdentifier("weather.temp") == "weather.temp")
        #expect(ItemID.usableIdentifier("x_NS:1") == "x_NS:1", "only a name that starts with it")
    }

    @Test func systemModuleFromIdentifier() {
        #expect(ItemID.systemModule(ofIdentifier: "com.apple.menuextra.clock") == "clock")
        for module in ["airdrop", "battery", "bluetooth", "clock", "controlcenter", "sound", "wifi"] {
            #expect(ItemID.systemModule(ofIdentifier: "com.apple.menuextra.\(module)") == module)
        }
        #expect(ItemID.systemModule(ofIdentifier: "com.apple.menuextra.") == nil)
        #expect(ItemID.systemModule(ofIdentifier: "com.apple.menuextra") == nil)
        #expect(ItemID.systemModule(ofIdentifier: "com.apple.menuextras.clock") == nil)
        #expect(ItemID.systemModule(ofIdentifier: "com.example.menuextra.clock") == nil)
        #expect(ItemID.systemModule(ofIdentifier: "") == nil)
    }

    @Test func aBundleIDThatReadsAsASystemItemIsNotRepresentable() {
        // "system::x" reads back as the system module ":x", so the bundle ID "system" with an identifier can't be told from it.
        let odd = ItemID(bundleID: "system", key: .identifier("x"))
        #expect(odd.string == "system::x")
        #expect(!odd.isRepresentable)
        #expect(ItemID(string: odd.string) != odd)
        #expect(throws: EncodingError.self) { try JSONEncoder().encode([odd]) }
        // The same bundle ID with an index is fine: "system#1" reads as it was.
        let indexed = ItemID(bundleID: "system", key: .index(1))
        #expect(indexed.isRepresentable)
        // So are the IDs that Mantel makes: an app's, an index, a system item.
        for id in [ItemID(bundleID: "com.example.app", key: .identifier("x")), ItemID(bundleID: "com.example.app", key: .index(0)), .system("clock")] {
            #expect(id.isRepresentable)
            #expect((try? JSONEncoder().encode([id])) != nil)
        }
        // A bundle ID with the separator in it splits in the wrong place; an empty part has no text form.
        #expect(!ItemID(bundleID: "com.example::app", key: .identifier("x")).isRepresentable)
        #expect(!ItemID(bundleID: "", key: .index(0)).isRepresentable)
        #expect(!ItemID(bundleID: "com.example.app", key: .identifier("")).isRepresentable)
    }

    @Test func aNegativeIndexIsNotRepresentable() {
        let negative = ItemID(bundleID: "com.example.app", key: .index(-1))
        #expect(negative.string == "com.example.app#-1")
        #expect(!negative.isRepresentable)
        #expect(ItemID(string: negative.string) == nil, "a minus sign isn't in the text form")
        #expect(throws: EncodingError.self) { try JSONEncoder().encode([negative]) }
        #expect(ItemID(bundleID: "com.example.app", key: .index(0)).isRepresentable)
    }
}
