import Foundation
import Testing

@testable import MKCore

@Suite("KeyCombo")
struct KeyComboTests {
    @Test func withoutFunctionDropsOnlyFn() {
        let combo = KeyCombo(keyCode: KeyCode.k, modifiers: [.command, .function])
        #expect(combo.withoutFunction == KeyCombo(keyCode: KeyCode.k, modifiers: .command))
        #expect(KeyCombo(keyCode: KeyCode.k, modifiers: .command).withoutFunction
            == KeyCombo(keyCode: KeyCode.k, modifiers: .command))
    }

    @Test func f1ThroughF20AreFunctionKeys() {
        let codes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        #expect(codes.count == 20)
        for code in codes {
            #expect(KeyCombo(keyCode: code, modifiers: []).isFunctionKey)
        }
        #expect(!KeyCombo(keyCode: KeyCode.k, modifiers: []).isFunctionKey)
        #expect(!KeyCombo(keyCode: KeyCode.space, modifiers: []).isFunctionKey)
    }

    @Test func aComboLacksAModifierUnlessItHasCommandControlOrOptionOrIsAFunctionKey() {
        #expect(KeyCombo(keyCode: KeyCode.k, modifiers: []).lacksModifier)
        // ⇧K would take every capital K typed anywhere; Fn isn't registered at all.
        #expect(KeyCombo(keyCode: KeyCode.k, modifiers: .shift).lacksModifier)
        #expect(KeyCombo(keyCode: KeyCode.k, modifiers: .function).lacksModifier)
        #expect(!KeyCombo(keyCode: KeyCode.k, modifiers: .command).lacksModifier)
        #expect(!KeyCombo(keyCode: KeyCode.k, modifiers: .control).lacksModifier)
        #expect(!KeyCombo(keyCode: KeyCode.k, modifiers: .option).lacksModifier)
        #expect(!KeyCombo(keyCode: KeyCode.f5, modifiers: []).lacksModifier)
        #expect(!KeyCombo(keyCode: KeyCode.f5, modifiers: .function).lacksModifier)
    }

    @Test func roundTripsThroughJSON() throws {
        let combo = KeyCombo(keyCode: 40, modifiers: [.control, .option, .command])
        let data = try JSONEncoder().encode(combo)
        #expect(try JSONDecoder().decode(KeyCombo.self, from: data) == combo)
    }
}
