import Foundation
import Testing

@testable import MKCore

@Suite("ModifierSet")
struct ModifierSetTests {
    /// The four modifiers Carbon can register: each with its `NSEvent.ModifierFlags` raw value and its Carbon mask
    /// (`shiftKey` 512, `cmdKey` 256, `optionKey` 2048, `controlKey` 4096).
    private static let representable: [(modifier: ModifierSet, cocoa: UInt, carbon: UInt32)] = [
        (.command, 1 << 20, 256),
        (.shift, 1 << 17, 512),
        (.option, 1 << 19, 2048),
        (.control, 1 << 18, 4096),
    ]

    /// All 16 combinations of the four, with the flags each one has in both worlds.
    private static let combinations: [(set: ModifierSet, cocoa: UInt, carbon: UInt32)] = (0..<16).map { bits in
        var set: ModifierSet = []
        var cocoa: UInt = 0
        var carbon: UInt32 = 0
        for (index, entry) in representable.enumerated() where bits & (1 << index) != 0 {
            set.insert(entry.modifier)
            cocoa |= entry.cocoa
            carbon |= entry.carbon
        }
        return (set, cocoa, carbon)
    }

    @Test func cocoaCarbonRoundTrip() {
        #expect(Self.combinations.count == 16)
        for combination in Self.combinations {
            let set = combination.set
            #expect(set.cocoaFlags == combination.cocoa)
            #expect(set.carbonFlags == combination.carbon)
            #expect(ModifierSet(cocoaFlags: combination.cocoa) == set)
            #expect(ModifierSet(carbonFlags: combination.carbon) == set)
            // Through the other world and back.
            #expect(ModifierSet(carbonFlags: ModifierSet(cocoaFlags: set.cocoaFlags).carbonFlags) == set)
            #expect(ModifierSet(cocoaFlags: ModifierSet(carbonFlags: set.carbonFlags).cocoaFlags) == set)
        }
    }

    @Test func functionIsDroppedInCarbon() {
        #expect(ModifierSet.function.carbonFlags == 0)
        #expect(ModifierSet([.command, .function]).carbonFlags == 256)
        #expect(ModifierSet([.control, .option, .shift, .command, .function]).carbonFlags == 4096 | 2048 | 512 | 256)
        // Carbon never says it: coming back from Carbon, Fn is not there.
        #expect(!ModifierSet(carbonFlags: ModifierSet([.command, .function]).carbonFlags).contains(.function))
    }

    @Test func functionSurvivesTheCocoaRoundTrip() {
        // Cocoa does say it, and the recorder keeps what it hears until the combo is registered.
        #expect(ModifierSet.function.cocoaFlags == 1 << 23)
        let set: ModifierSet = [.control, .function]
        #expect(ModifierSet(cocoaFlags: set.cocoaFlags) == set)
    }

    @Test func cocoaFlagsOutsideTheFiveAreIgnored() {
        // Caps Lock, the numeric pad and Help are in `NSEvent.ModifierFlags` too (arrow keys carry the numeric pad flag),
        // and its low bits are device-dependent: none of them is a modifier of a shortcut.
        let capsLock: UInt = 1 << 16
        let numericPad: UInt = 1 << 21
        let help: UInt = 1 << 22
        let deviceBits: UInt = 0x0102
        #expect(ModifierSet(cocoaFlags: capsLock | numericPad | help | deviceBits).isEmpty)
        #expect(ModifierSet(cocoaFlags: (1 << 20) | capsLock | numericPad | deviceBits) == .command)
        #expect(ModifierSet(cocoaFlags: 0).isEmpty)
    }

    @Test func carbonFlagsOutsideTheFourAreIgnored() {
        let alphaLock: UInt32 = 1 << 10
        let numLock: UInt32 = 1 << 16
        #expect(ModifierSet(carbonFlags: alphaLock | numLock).isEmpty)
        #expect(ModifierSet(carbonFlags: alphaLock | 256) == .command)
    }

    // MARK: Codable

    private func json(_ set: ModifierSet) throws -> String {
        String(decoding: try JSONEncoder().encode(set), as: UTF8.self)
    }

    @Test func isWrittenAsModifierNamesInGlyphOrder() throws {
        #expect(try json([]) == "[]")
        #expect(try json(.command) == #"["command"]"#)
        #expect(try json([.command, .control]) == #"["control","command"]"#)
        #expect(try json([.function, .shift, .option, .control, .command])
            == #"["control","option","shift","command","function"]"#)
    }

    @Test func namesDecodeInAnyOrder() throws {
        let decoded = try JSONDecoder().decode(ModifierSet.self, from: Data(#"["command","control"]"#.utf8))
        #expect(decoded == [.control, .command])
        #expect(try JSONDecoder().decode(ModifierSet.self, from: Data("[]".utf8)).isEmpty)
    }

    @Test func everyCombinationRoundTripsThroughJSON() throws {
        for bits in 0..<32 {
            let set = ModifierSet(rawValue: UInt8(bits))
            let data = try JSONEncoder().encode(set)
            #expect(try JSONDecoder().decode(ModifierSet.self, from: data) == set)
        }
    }

    @Test func anUnknownNameIsAnErrorRatherThanADroppedModifier() {
        // Dropping it would turn ⌘⇧K into ⌘K without a word.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ModifierSet.self, from: Data(#"["command","hyper"]"#.utf8))
        }
    }
}
