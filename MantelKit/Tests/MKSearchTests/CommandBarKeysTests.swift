import AppKit
import MKCore
import Testing

@testable import MKSearch

/// What the keys of the command bar do, and the hints under its results.
@Suite("Command bar keys", .timeLimit(.minutes(1)))
struct CommandBarKeysTests {
    private static let returnKey: UInt16 = 36
    private static let keypadEnter: UInt16 = 76
    private static let icon = SearchResultKind.icon(ItemID(bundleID: "com.example.notes", key: .identifier("main")))
    private static let action = SearchResultKind.action(.showHidden)

    private func press(_ keyCode: UInt16, _ modifiers: ModifierSet = [], on selected: SearchResultKind? = icon, right: Bool = true,
                       option: Bool = true) -> CommandBarActivation {
        CommandBarKeys.activation(keyCode: keyCode, modifiers: modifiers, selected: selected, postedRightWorks: right, postedOptionWorks: option)
    }

    @Test func returnClicksAnIcon() {
        #expect(press(Self.returnKey) == .click(.left))
        #expect(press(Self.keypadEnter) == .click(.left))
        // Fn is held by the arrow keys and means nothing for Return.
        #expect(press(Self.returnKey, [.function]) == .click(.left))
    }

    @Test func optionReturnOptionClicks() {
        #expect(press(Self.returnKey, [.option]) == .click(.option))
        // An option click that doesn't arrive is still asked for as one: the click driver makes it a left click and says so.
        #expect(press(Self.returnKey, [.option], option: false) == .click(.option))
    }

    @Test func commandReturnRightClicks() {
        #expect(press(Self.returnKey, [.command]) == .click(.right))
        // ⌘ wins over ⌥ when both are held.
        #expect(press(Self.returnKey, [.command, .option]) == .click(.right))
    }

    @Test func shiftReturnShows() {
        #expect(press(Self.returnKey, [.shift]) == .show)
        #expect(press(Self.keypadEnter, [.shift]) == .show)
        // It doesn't click, so it wins over the keys that say how.
        #expect(press(Self.returnKey, [.shift, .command]) == .show)
        #expect(press(Self.returnKey, [.shift, .option]) == .show)
    }

    @Test func anyReturnRunsAnAction() {
        let modifiers: [ModifierSet] = [[], [.option], [.command], [.shift], [.command, .option, .shift]]
        for held in modifiers {
            #expect(press(Self.returnKey, held, on: Self.action) == .run, "\(held)")
        }
        #expect(press(Self.keypadEnter, on: Self.action) == .run)
    }

    @Test func postedKindsOffMakeLeftClicks() {
        // A right click that can't be posted is a left click, with or without the option click working.
        #expect(press(Self.returnKey, [.command], right: false) == .click(.left))
        #expect(press(Self.returnKey, [.command], right: false, option: false) == .click(.left))
        // The plain click, the show and an action are the same either way.
        #expect(press(Self.returnKey, right: false, option: false) == .click(.left))
        #expect(press(Self.returnKey, [.shift], right: false, option: false) == .show)
        #expect(press(Self.returnKey, [.command], on: Self.action, right: false, option: false) == .run)
    }

    @Test func nothingSelectedSwallowsReturn() {
        // Not `.ignored`: the field would take Return, end its editing and select its text.
        #expect(press(Self.returnKey, on: nil) == .nothing)
        #expect(press(Self.returnKey, [.shift], on: nil) == .nothing)
        #expect(press(Self.keypadEnter, on: nil) == .nothing)
        #expect(press(Self.returnKey, on: Self.icon) != .nothing)
        // Other keys are still the field's.
        #expect(press(0, on: nil) == .ignored)
    }

    @Test func commandKeysAreTheFieldsEditingActions() {
        #expect(CommandBarKeys.editing(characters: "v", modifiers: [.command]) == .paste)
        #expect(CommandBarKeys.editing(characters: "c", modifiers: [.command]) == .copy)
        #expect(CommandBarKeys.editing(characters: "x", modifiers: [.command]) == .cut)
        #expect(CommandBarKeys.editing(characters: "a", modifiers: [.command]) == .selectAll)
        #expect(CommandBarKeys.editing(characters: "z", modifiers: [.command]) == .undo)
        #expect(CommandBarKeys.editing(characters: "z", modifiers: [.command, .shift]) == .redo)
        // The character is what counts, in either case (⇧ makes it a capital).
        #expect(CommandBarKeys.editing(characters: "Z", modifiers: [.command, .shift]) == .redo)
        #expect(CommandBarKeys.editing(characters: "V", modifiers: [.command]) == .paste)
    }

    @Test func otherKeysAreNotEditingActions() {
        #expect(CommandBarKeys.editing(characters: "v", modifiers: []) == nil)
        #expect(CommandBarKeys.editing(characters: "v", modifiers: [.shift]) == nil)
        #expect(CommandBarKeys.editing(characters: "v", modifiers: [.command, .option]) == nil)
        #expect(CommandBarKeys.editing(characters: "v", modifiers: [.command, .control]) == nil)
        #expect(CommandBarKeys.editing(characters: "v", modifiers: [.command, .shift]) == nil)
        #expect(CommandBarKeys.editing(characters: "q", modifiers: [.command]) == nil)
        #expect(CommandBarKeys.editing(characters: "", modifiers: [.command]) == nil)
    }

    @Test func escapeCloses() {
        #expect(press(53) == .close)
        #expect(press(53, on: nil) == .close)
        #expect(press(53, on: Self.action) == .close)
    }

    @Test func arrowsMove() {
        #expect(press(126) == .moveUp)
        #expect(press(125) == .moveDown)
        // They move whether or not anything is selected (the first press selects), and with Fn, which arrows report.
        #expect(press(126, on: nil) == .moveUp)
        #expect(press(125, [.function], on: nil) == .moveDown)
        // Left, right, a letter and Tab are the search field's.
        for keyCode: UInt16 in [123, 124, 0, 48, 49] {
            #expect(press(keyCode) == .ignored, "\(keyCode)")
        }
    }

    @Test func footerForEachKind() {
        func footer(_ kind: SearchResultKind?, right: Bool, option: Bool) -> String {
            CommandBarKeys.footer(for: kind, postedRightWorks: right, postedOptionWorks: option)
        }
        #expect(footer(Self.icon, right: true, option: true) == "↩ Click  ⌥↩ Option-click  ⌘↩ Right-click  ⇧↩ Show")
        // What was measured: right clicks arrive, option clicks come through as left clicks.
        #expect(footer(Self.icon, right: true, option: false) == "↩ Click  ⌘↩ Right-click  ⇧↩ Show")
        #expect(footer(Self.icon, right: false, option: true) == "↩ Click  ⌥↩ Option-click  ⇧↩ Show")
        #expect(footer(Self.icon, right: false, option: false) == "↩ Click  ⇧↩ Show")
        #expect(footer(Self.action, right: true, option: true) == "↩ Run")
        #expect(footer(Self.action, right: false, option: false) == "↩ Run")
        #expect(footer(nil, right: true, option: true) == "")
    }

    // MARK: Titles and symbols

    @Test func matchedCharactersAreTheirOwnRuns() {
        #expect(CommandBarTitle.runs(of: "Notes", matching: [0, 1, 4]) == [
            CommandBarTitleRun(text: "No", matched: true), CommandBarTitleRun(text: "te", matched: false),
            CommandBarTitleRun(text: "s", matched: true),
        ])
        #expect(CommandBarTitle.runs(of: "Notes", matching: []) == [CommandBarTitleRun(text: "Notes", matched: false)])
        #expect(CommandBarTitle.runs(of: "", matching: [0]).isEmpty)
        // An offset past the end names no character, and the title is still all there.
        let past = CommandBarTitle.runs(of: "Ab", matching: [1, 9])
        #expect(past == [CommandBarTitleRun(text: "A", matched: false), CommandBarTitleRun(text: "b", matched: true)])
        #expect(past.map(\.text).joined() == "Ab")
    }

    @Test func everyActionHasASymbolThatExists() {
        for action in CommandBarActionID.allCases {
            #expect(NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil) != nil, "\(action.rawValue)")
        }
    }
}
