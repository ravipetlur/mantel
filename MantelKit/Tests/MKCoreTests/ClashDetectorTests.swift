import Foundation
import Testing

@testable import MKCore

@Suite("ClashDetector")
struct ClashDetectorTests {
    private let openSettings = HotkeyID.openSettings
    private let other = HotkeyID(rawValue: "another-action")

    private let controlOptionCommandK = KeyCombo(keyCode: KeyCode.k, modifiers: [.control, .option, .command])
    private let spotlight = SymbolicHotkey(id: 64, combo: KeyCombo(keyCode: KeyCode.space, modifiers: .command),
                                           name: "Show Spotlight search")

    private func clashes(_ combo: KeyCombo, id: HotkeyID? = nil, mantel: [HotkeyID: KeyCombo] = [:],
                         system: [SymbolicHotkey] = []) -> [HotkeyClash] {
        ClashDetector.clashes(for: combo, assigning: id ?? openSettings, mantel: mantel, system: system)
    }

    @Test func sameMantelComboIsAClash() {
        #expect(clashes(controlOptionCommandK, mantel: [other: controlOptionCommandK]) == [.mantel(other)])
    }

    @Test func aDifferentMantelComboIsNot() {
        let different = KeyCombo(keyCode: KeyCode.j, modifiers: [.control, .option, .command])
        #expect(clashes(controlOptionCommandK, mantel: [other: different]).isEmpty)
        // Same key, other modifiers.
        let sameKey = KeyCombo(keyCode: KeyCode.k, modifiers: [.control, .command])
        #expect(clashes(controlOptionCommandK, mantel: [other: sameKey]).isEmpty)
    }

    @Test func reassigningSameIdIsNotAClash() {
        // The map holds the id's current combo, which is the one being recorded again.
        #expect(clashes(controlOptionCommandK, mantel: [openSettings: controlOptionCommandK]).isEmpty)
    }

    @Test func everyOtherActionWithTheComboIsNamed() {
        let third = HotkeyID(rawValue: "third-action")
        let found = clashes(controlOptionCommandK, mantel: [other: controlOptionCommandK, third: controlOptionCommandK,
                                                            openSettings: controlOptionCommandK])
        #expect(found == [.mantel(other), .mantel(third)])
    }

    @Test func enabledSystemShortcutIsAClash() {
        #expect(clashes(spotlight.combo, system: [spotlight]) == [.system(spotlight)])
    }

    @Test func aSystemShortcutWithOtherModifiersOrAnotherKeyIsNot() {
        let optionCommandSpace = KeyCombo(keyCode: KeyCode.space, modifiers: [.option, .command])
        let commandReturn = KeyCombo(keyCode: KeyCode.returnKey, modifiers: .command)
        #expect(clashes(optionCommandSpace, system: [spotlight]).isEmpty)
        #expect(clashes(commandReturn, system: [spotlight]).isEmpty)
    }

    @Test func aSystemShortcutThatCarriesFnClashesWithTheSameComboWithoutIt() {
        // Arrow keys report Fn on their own, so macOS keeps ⌃← as Fn+⌃+←, and Mantel registers it as ⌃←.
        let moveLeft = SymbolicHotkey(id: 79, combo: KeyCombo(keyCode: KeyCode.leftArrow, modifiers: [.control, .function]),
                                      name: "Move left a space")
        let recorded = KeyCombo(keyCode: KeyCode.leftArrow, modifiers: .control)
        #expect(clashes(recorded, system: [moveLeft]) == [.system(moveLeft)])
        // And the other way round: a recorded combo that has Fn is registered without it.
        let recordedWithFn = KeyCombo(keyCode: KeyCode.leftArrow, modifiers: [.control, .function])
        let plain = SymbolicHotkey(id: 79, combo: recorded, name: "Move left a space")
        #expect(clashes(recordedWithFn, system: [plain]) == [.system(plain)])
    }

    @Test func systemShortcutsAreReportedInOrderOfId() {
        let first = SymbolicHotkey(id: 5, combo: spotlight.combo, name: nil)
        let second = SymbolicHotkey(id: 9, combo: spotlight.combo, name: nil)
        #expect(clashes(spotlight.combo, system: [second, first]) == [.system(first), .system(second)])
    }

    @Test func optionOnlyIsFlagged() {
        let combo = KeyCombo(keyCode: KeyCode.k, modifiers: .option)
        #expect(clashes(combo) == [.optionOnly])
    }

    @Test func optionShiftOnlyIsFlagged() {
        let combo = KeyCombo(keyCode: KeyCode.k, modifiers: [.option, .shift])
        #expect(clashes(combo) == [.optionOnly])
    }

    @Test func optionWithCommandOrControlIsNotFlagged() {
        #expect(clashes(KeyCombo(keyCode: KeyCode.k, modifiers: [.option, .command])).isEmpty)
        #expect(clashes(KeyCombo(keyCode: KeyCode.k, modifiers: [.option, .control])).isEmpty)
        #expect(clashes(KeyCombo(keyCode: KeyCode.k, modifiers: [.option, .shift, .command])).isEmpty)
    }

    @Test func functionIsLeftOutWhenDecidingWhatTheModifiersAre() {
        // Registered, ⌥+Fn is ⌥.
        #expect(clashes(KeyCombo(keyCode: KeyCode.k, modifiers: [.option, .function])) == [.optionOnly])
        #expect(clashes(KeyCombo(keyCode: KeyCode.k, modifiers: [.command, .function])).isEmpty)
    }

    @Test func functionKeyAloneIsAllowed() {
        #expect(clashes(KeyCombo(keyCode: KeyCode.f5, modifiers: [])).isEmpty)
        #expect(clashes(KeyCombo(keyCode: KeyCode.f20, modifiers: [])).isEmpty)
        #expect(clashes(KeyCombo(keyCode: KeyCode.f1, modifiers: .shift)).isEmpty)
    }

    @Test func plainLetterIsNoModifier() {
        #expect(clashes(KeyCombo(keyCode: KeyCode.k, modifiers: [])) == [.noModifier])
    }

    @Test func shiftAloneIsNoModifierToo() {
        // The message asks for ⌘, ⌃ or ⌥: ⇧K would take every capital K typed anywhere.
        #expect(clashes(KeyCombo(keyCode: KeyCode.k, modifiers: .shift)) == [.noModifier])
        #expect(clashes(KeyCombo(keyCode: KeyCode.k, modifiers: .function)) == [.noModifier])
    }

    @Test func aComboWithoutAModifierIsOnlyThat() {
        // It isn't saved, so nothing else about it matters.
        let bare = KeyCombo(keyCode: KeyCode.k, modifiers: [])
        let clash = SymbolicHotkey(id: 1, combo: bare, name: nil)
        #expect(clashes(bare, mantel: [other: bare], system: [clash]) == [.noModifier])
    }

    @Test func clashesComeMantelFirstThenSystemThenOption() {
        let combo = KeyCombo(keyCode: KeyCode.space, modifiers: .option)
        let system = SymbolicHotkey(id: 3, combo: combo, name: nil)
        #expect(clashes(combo, mantel: [other: combo], system: [system]) == [.mantel(other), .system(system), .optionOnly])
    }

    @Test func onlyAMissingModifierKeepsAComboFromBeingSaved() {
        #expect(HotkeyClash.noModifier.preventsSaving)
        #expect(!HotkeyClash.optionOnly.preventsSaving)
        #expect(!HotkeyClash.mantel(other).preventsSaving)
        #expect(!HotkeyClash.system(spotlight).preventsSaving)
    }

    // MARK: What the person reads

    private func message(_ clash: HotkeyClash) -> String {
        clash.message(actionTitle: { $0 == .openSettings ? "Open Mantel settings" : nil })
    }

    @Test func theMessagesSayWhatEachClashIs() {
        #expect(message(.mantel(.openSettings)) == "Already used by Mantel: Open Mantel settings")
        #expect(message(.system(spotlight)) == "Used by macOS: Show Spotlight search")
        #expect(message(.optionOnly) == "macOS may block shortcuts that use only ⌥")
        #expect(message(.noModifier) == "Add ⌘, ⌃ or ⌥")
    }

    @Test func aSystemShortcutWithoutANameIsASystemShortcut() {
        let unnamed = SymbolicHotkey(id: 9999, combo: spotlight.combo, name: nil)
        #expect(message(.system(unnamed)) == "Used by macOS: a system shortcut")
    }

    @Test func anActionWithoutATitleIsNamedByItsId() {
        #expect(message(.mantel(other)) == "Already used by Mantel: another-action")
    }

    // MARK: macOS's shortcuts as the plist gives them, defaults included

    /// What the Hotkeys pane checks against: the plist run through `SymbolicHotkeys.parse`.
    private func system(_ plist: [String: Any]) -> [SymbolicHotkey] {
        SymbolicHotkeys.parse(plist)
    }

    private let leftArrowWithControl = KeyCombo(keyCode: KeyCode.leftArrow, modifiers: .control)
    private let spotlightCombo = KeyCombo(keyCode: KeyCode.space, modifiers: .command)

    @Test func untouchedDefaultIsAClash() {
        // How macOS 27 keeps ids 79 to 82 (⌃← and the like): enabled, with no value.
        let shortcuts = system(["79": ["enabled": true]])
        let found = clashes(leftArrowWithControl, system: shortcuts)
        #expect(found.count == 1)
        guard case .system(let shortcut)? = found.first else {
            Issue.record("expected a macOS clash, got \(found)")
            return
        }
        #expect(shortcut.id == 79)
        #expect(shortcut.name == "Move left a space")
        #expect(message(found[0]) == "Used by macOS: Move left a space")
    }

    @Test func absentDefaultIsAClash() {
        // Nothing in the plist at all: ⌘Space is still Spotlight's.
        let found = clashes(spotlightCombo, system: system([:]))
        #expect(found.count == 1)
        guard case .system(let shortcut)? = found.first else {
            Issue.record("expected a macOS clash, got \(found)")
            return
        }
        #expect(shortcut.id == 64)
    }

    @Test func disabledDefaultIsNotAClash() {
        let plist: [String: Any] = ["64": ["enabled": false]]
        #expect(clashes(spotlightCombo, system: system(plist)).isEmpty)
        // And with the value still in the file, which is how a switched-off shortcut is usually kept.
        let kept: [String: Any] = ["64": ["enabled": false, "value": ["type": "standard", "parameters": [32, 49, 1_048_576]] as [String: Any]]]
        #expect(clashes(spotlightCombo, system: system(kept)).isEmpty)
    }

    @Test func customValueOverridesDefault() {
        // Spotlight moved to ⌃⌥K: ⌘Space is free, and ⌃⌥K is not.
        let moved: [String: Any] = ["64": ["enabled": true, "value": ["type": "standard", "parameters": [107, 40, 786_432]] as [String: Any]]]
        #expect(clashes(spotlightCombo, system: system(moved)).isEmpty)
        let found = clashes(KeyCombo(keyCode: KeyCode.k, modifiers: [.control, .option]), system: system(moved))
        guard case .system(let shortcut)? = found.first else {
            Issue.record("expected a macOS clash, got \(found)")
            return
        }
        #expect(shortcut.id == 64)
    }
}
