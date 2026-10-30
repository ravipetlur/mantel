import Foundation
import Testing

@testable import MKCore

@Suite("SymbolicHotkeys", .timeLimit(.minutes(2)))
struct SymbolicHotkeysTests {
    /// What the plist says on its own, without macOS's defaults for the ids it leaves out (those have tests of their own).
    private func parseAlone(_ plist: [String: Any]) -> [SymbolicHotkey] {
        SymbolicHotkeys.parse(plist, defaults: [])
    }

    /// The shortcut of one id out of what `parse` answers with macOS's defaults in play.
    private func parsed(_ plist: [String: Any], id: Int) -> SymbolicHotkey? {
        SymbolicHotkeys.parse(plist).first { $0.id == id }
    }

    /// One entry of `AppleSymbolicHotKeys`, as `defaults` reads it.
    private func entry(_ parameters: [Int], enabled: Bool = true, type: String = "standard") -> [String: Any] {
        ["enabled": enabled, "value": ["parameters": parameters, "type": type] as [String: Any]]
    }

    private var fixture: [String: Any] {
        [
            "64": entry([32, 49, 1_048_576]),         // ⌘Space, Show Spotlight search
            "60": entry([32, 49, 262_144]),           // ⌃Space, Select the previous input source
            "79": entry([65535, 123, 8_650_752]),     // ⌃←, which arrow keys report with Fn
        ]
    }

    @Test func parsesEnabledEntries() {
        let parsed = parseAlone(fixture)
        #expect(parsed == [
            SymbolicHotkey(id: 60, combo: KeyCombo(keyCode: 49, modifiers: .control), name: "Select the previous input source"),
            SymbolicHotkey(id: 64, combo: KeyCombo(keyCode: 49, modifiers: .command), name: "Show Spotlight search"),
            SymbolicHotkey(id: 79, combo: KeyCombo(keyCode: 123, modifiers: [.control, .function]), name: "Move left a space"),
        ])
    }

    @Test func disabledEntriesAreIgnored() {
        var plist = fixture
        plist["64"] = entry([32, 49, 1_048_576], enabled: false)
        let ids = parseAlone(plist).map(\.id)
        #expect(ids == [60, 79])
    }

    @Test func noKeyEntriesAreIgnored() {
        // 65535 is "no key": an entry whose shortcut was cleared keeps its place in the file.
        var plist = fixture
        plist["162"] = entry([65535, 65535, 0])
        plist["163"] = entry([32, 65535, 1_048_576])
        let ids = parseAlone(plist).map(\.id)
        #expect(ids == [60, 64, 79])
    }

    @Test func anIdThatIsNotInTheTableHasNoName() {
        let parsed = parseAlone(["9999": entry([32, 49, 1_048_576])])
        #expect(parsed.count == 1)
        #expect(parsed.first?.name == nil)
        #expect(parsed.first?.id == 9999)
    }

    @Test func entriesAreInOrderOfId() {
        let plist: [String: Any] = ["200": entry([0, 0, 1_048_576]), "7": entry([0, 1, 1_048_576]), "64": entry([0, 2, 1_048_576])]
        #expect(parseAlone(plist).map(\.id) == [7, 64, 200])
    }

    @Test func entriesThatAreNotShapedLikeAShortcutAreSkipped() {
        let plist: [String: Any] = [
            "10": ["enabled": true],                                                          // no value
            "11": ["enabled": true, "value": ["type": "standard"]],                           // no parameters
            "12": ["enabled": true, "value": ["parameters": [32, 49], "type": "standard"]],   // too few
            "13": ["enabled": true, "value": ["parameters": ["a", "b", "c"], "type": "standard"]],
            "14": ["value": ["parameters": [32, 49, 1_048_576], "type": "standard"]],         // no enabled flag
            "15": "not an entry",
            "banana": entry([32, 49, 1_048_576]),                                             // not an id
            "16": entry([32, 49, 1_048_576], type: "button"),                                 // another kind of entry
            "64": entry([32, 49, 1_048_576]),
        ]
        #expect(parseAlone(plist).map(\.id) == [64])
    }

    @Test func numbersFromTheDefaultsDatabaseAreRead() {
        // `UserDefaults` hands back NSNumber, for the flag and for each parameter.
        let plist: [String: Any] = [
            "64": [
                "enabled": NSNumber(value: true),
                "value": ["parameters": [NSNumber(value: 32), NSNumber(value: 49), NSNumber(value: 1_048_576)], "type": "standard"] as [String: Any],
            ] as [String: Any],
        ]
        #expect(parseAlone(plist).map(\.combo) == [KeyCombo(keyCode: 49, modifiers: .command)])
    }

    @Test func aKeyCodeOutsideTheRangeIsSkippedNotACrash() {
        let plist: [String: Any] = ["20": entry([32, 70000, 1_048_576]), "21": entry([32, -3, 1_048_576])]
        #expect(parseAlone(plist).isEmpty)
    }

    @Test func anEmptyDictionaryHasNoShortcuts() {
        #expect(parseAlone([:]).isEmpty)
    }

    // MARK: macOS's defaults

    private func combo(_ keyCode: UInt16, _ modifiers: ModifierSet) -> KeyCombo {
        KeyCombo(keyCode: keyCode, modifiers: modifiers)
    }

    @Test func theTableHoldsTheFifteenCommonDefaults() {
        let expected: [SymbolicHotkey] = [
            SymbolicHotkey(id: 27, combo: combo(50, .command), name: "Move focus to next window"),
            SymbolicHotkey(id: 28, combo: combo(20, [.shift, .command]), name: "Save picture of screen as a file"),
            SymbolicHotkey(id: 29, combo: combo(20, [.control, .shift, .command]), name: "Copy picture of screen to the clipboard"),
            SymbolicHotkey(id: 30, combo: combo(21, [.shift, .command]), name: "Save picture of selected area as a file"),
            SymbolicHotkey(id: 31, combo: combo(21, [.control, .shift, .command]), name: "Copy picture of selected area to the clipboard"),
            SymbolicHotkey(id: 32, combo: combo(KeyCode.upArrow, .control), name: "Mission Control"),
            SymbolicHotkey(id: 33, combo: combo(KeyCode.downArrow, .control), name: "Application windows"),
            SymbolicHotkey(id: 36, combo: combo(103, []), name: "Show Desktop"),
            SymbolicHotkey(id: 60, combo: combo(KeyCode.space, .control), name: "Select the previous input source"),
            SymbolicHotkey(id: 61, combo: combo(KeyCode.space, [.control, .option]), name: "Select next source in Input menu"),
            SymbolicHotkey(id: 64, combo: combo(KeyCode.space, .command), name: "Show Spotlight search"),
            SymbolicHotkey(id: 65, combo: combo(KeyCode.space, [.option, .command]), name: "Show Finder search window"),
            SymbolicHotkey(id: 79, combo: combo(KeyCode.leftArrow, .control), name: "Move left a space"),
            SymbolicHotkey(id: 81, combo: combo(KeyCode.rightArrow, .control), name: "Move right a space"),
            SymbolicHotkey(id: 184, combo: combo(23, [.shift, .command]), name: "Screenshot and recording options"),
        ]
        #expect(SymbolicHotkeys.defaults == expected)
    }

    @Test func theTableAgreesWithWhatARealMacKeepsInItsPlist() {
        // The values of ids 28-31, 60, 61, 64 and 184 as read from `com.apple.symbolichotkeys` on a Mac running macOS 27 (their `enabled`
        // flags are whatever the person set, so they are given as enabled here).
        let kept: [String: Any] = [
            "28": entry([51, 20, 1_179_648]), "29": entry([51, 20, 1_441_792]),
            "30": entry([52, 21, 1_179_648]), "31": entry([52, 21, 1_441_792]),
            "60": entry([32, 49, 262_144]), "61": entry([32, 49, 786_432]), "64": entry([32, 49, 1_048_576]),
            "184": entry([53, 23, 1_179_648]),
        ]
        let fromThePlist = parseAlone(kept)
        #expect(fromThePlist.map(\.id) == [28, 29, 30, 31, 60, 61, 64, 184])
        for shortcut in fromThePlist {
            let inTheTable = SymbolicHotkeys.defaults.first { $0.id == shortcut.id }
            #expect(inTheTable?.combo == shortcut.combo)
        }
    }

    @Test func anEmptyPlistIsEveryDefaultSwitchedOn() {
        // Nothing is in the plist until the person changes a shortcut, and then the others are as macOS ships them.
        #expect(SymbolicHotkeys.parse([:]) == SymbolicHotkeys.defaults.sorted { $0.id < $1.id })
    }

    @Test func anEnabledEntryWithoutAValueIsTheDefault() {
        // How macOS 27 stores ids 79 to 82: enabled, and nothing else.
        let shortcut = parsed(["79": ["enabled": true]], id: 79)
        #expect(shortcut == SymbolicHotkey(id: 79, combo: combo(KeyCode.leftArrow, .control), name: "Move left a space"))
    }

    @Test func anEnabledEntryWithoutAValueForAnIdThatIsNotInTheTableIsNothing() {
        #expect(parsed(["9999": ["enabled": true]], id: 9999) == nil)
        #expect(parsed(["262": ["enabled": true]], id: 262) == nil)
    }

    @Test func aDisabledEntryIsSkippedWithOrWithoutAValue() {
        #expect(parsed(["64": ["enabled": false]], id: 64) == nil)
        #expect(parsed(["64": entry([32, 49, 1_048_576], enabled: false)], id: 64) == nil)
        #expect(parsed(["64": ["enabled": NSNumber(value: false)]], id: 64) == nil)
        // The rest of the defaults stay.
        #expect(parsed(["64": ["enabled": false]], id: 60) != nil)
    }

    @Test func aRealValueWinsOverTheDefault() {
        let custom = parsed(["64": entry([107, 40, 786_432])], id: 64)    // ⌃⌥K
        #expect(custom == SymbolicHotkey(id: 64, combo: combo(KeyCode.k, [.control, .option]), name: "Show Spotlight search"))
    }

    @Test func aClearedShortcutStaysClearedWhateverTheTableSays() {
        #expect(parsed(["64": entry([65535, 65535, 0])], id: 64) == nil)
    }

    @Test func aValueThatIsNotAShortcutIsNotReplacedByTheDefault() {
        // Only a missing value means "as shipped". One that is there and unreadable is left out rather than guessed at.
        #expect(parsed(["64": ["enabled": true, "value": "garbage"]], id: 64) == nil)
        #expect(parsed(["64": ["enabled": true, "value": ["type": "standard"]]], id: 64) == nil)
        #expect(parsed(["64": "not an entry"], id: 64) == nil)
    }

    @Test func onlyIdsInTheTableHaveANameAndTheRestAreNamedBySayingSo() {
        let shortcuts = SymbolicHotkeys.parse(["263": entry([32, 49, 1_179_648]), "64": entry([32, 49, 1_048_576])])
        #expect(shortcuts.first { $0.id == 263 }?.name == nil)
        #expect(shortcuts.first { $0.id == 64 }?.name == "Show Spotlight search")
        // The table is the whole list of names: every other id would show "a system shortcut".
        #expect(SymbolicHotkeys.defaults.allSatisfy { $0.name != nil })
    }
}
