import Foundation
import Testing

@testable import MKCore

/// What the keyboard layout would say for a few keys.
private struct FakeTranslator: KeyTranslating {
    var characters: [UInt16: String] = [KeyCode.k: "k", KeyCode.a: "a", 18: "1"]

    func character(for keyCode: UInt16) -> String? { characters[keyCode] }
}

@Suite("KeyNames")
struct KeyNamesTests {
    private func display(_ keyCode: UInt16, _ modifiers: ModifierSet, translator: some KeyTranslating = FakeTranslator()) -> String {
        KeyNames.display(KeyCombo(keyCode: keyCode, modifiers: modifiers), translator: translator)
    }

    @Test func modifierGlyphsComeInTheOrderControlOptionShiftCommand() {
        #expect(display(KeyCode.k, [.command, .shift, .option, .control]) == "⌃⌥⇧⌘K")
        #expect(display(KeyCode.k, [.command, .option, .control]) == "⌃⌥⌘K")
        #expect(display(KeyCode.k, [.command, .shift]) == "⇧⌘K")
        #expect(display(KeyCode.k, .command) == "⌘K")
        #expect(display(KeyCode.k, []) == "K")
    }

    @Test func functionKeyNamesItself() {
        #expect(display(KeyCode.f5, .command) == "⌘F5")
        #expect(display(KeyCode.f5, []) == "F5")
        #expect(display(KeyCode.f20, .control) == "⌃F20")
    }

    @Test func everyFunctionKeyHasItsNumber() {
        let codes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (index, code) in codes.enumerated() {
            #expect(display(code, []) == "F\(index + 1)")
        }
    }

    @Test func spaceIsAWord() {
        #expect(display(KeyCode.space, .option) == "⌥Space")
    }

    @Test func aLetterComesFromTheTranslatorInCapitals() {
        #expect(display(KeyCode.k, .command) == "⌘K")
        #expect(display(KeyCode.a, .control) == "⌃A")
        #expect(display(18, .command) == "⌘1")
        // A layout that puts another letter on the key.
        let dvorak = FakeTranslator(characters: [KeyCode.k: "t"])
        #expect(display(KeyCode.k, .command, translator: dvorak) == "⌘T")
    }

    @Test func theSpecialKeysComeFromATableNotTheTranslator() {
        // The translator would say something odd (or a control character) for each of these.
        let confused = FakeTranslator(characters: [
            KeyCode.space: " ", KeyCode.returnKey: "\r", KeyCode.tab: "\t", KeyCode.delete: "\u{8}",
            KeyCode.escape: "\u{1B}", KeyCode.leftArrow: "\u{1C}",
        ])
        #expect(display(KeyCode.space, [], translator: confused) == "Space")
        #expect(display(KeyCode.returnKey, [], translator: confused) == "Return")
        #expect(display(KeyCode.tab, [], translator: confused) == "Tab")
        #expect(display(KeyCode.delete, [], translator: confused) == "Delete")
        #expect(display(KeyCode.escape, [], translator: confused) == "Esc")
        #expect(display(KeyCode.leftArrow, [], translator: confused) == "←")
    }

    @Test func everySpecialKeyHasAName() {
        #expect(display(KeyCode.returnKey, .command) == "⌘Return")
        #expect(display(KeyCode.tab, .control) == "⌃Tab")
        #expect(display(KeyCode.delete, .command) == "⌘Delete")
        #expect(display(KeyCode.forwardDelete, .command) == "⌘Forward Delete")
        #expect(display(KeyCode.escape, .command) == "⌘Esc")
        #expect(display(KeyCode.home, []) == "Home")
        #expect(display(KeyCode.end, []) == "End")
        #expect(display(KeyCode.pageUp, []) == "Page Up")
        #expect(display(KeyCode.pageDown, []) == "Page Down")
        #expect(display(KeyCode.leftArrow, .control) == "⌃←")
        #expect(display(KeyCode.rightArrow, .control) == "⌃→")
        #expect(display(KeyCode.upArrow, .control) == "⌃↑")
        #expect(display(KeyCode.downArrow, .control) == "⌃↓")
    }

    @Test func fnIsNotShownBecauseItIsNotRegistered() {
        #expect(display(KeyCode.k, [.command, .function]) == "⌘K")
        // Arrow keys carry Fn on their own.
        #expect(display(KeyCode.leftArrow, [.control, .function]) == "⌃←")
        #expect(display(KeyCode.k, [.control, .option, .shift, .command, .function]) == "⌃⌥⇧⌘K")
    }

    @Test func aKeyTheLayoutHasNoCharacterForShowsItsCode() {
        #expect(display(200, .command) == "⌘Key 200")
        // The translator may answer with nothing or with a control character.
        let nothing = FakeTranslator(characters: [200: "", 201: "\u{7}"])
        #expect(display(200, .command, translator: nothing) == "⌘Key 200")
        #expect(display(201, .command, translator: nothing) == "⌘Key 201")
    }

    @Test func glyphsAloneAreOrderedAndLeaveOutFn() {
        #expect(KeyNames.glyphs(for: [.command, .function, .control]) == "⌃⌘")
        #expect(KeyNames.glyphs(for: []) == "")
    }
}
