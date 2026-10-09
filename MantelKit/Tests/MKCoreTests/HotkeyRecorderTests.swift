import Foundation
import Testing

@testable import MKCore

/// What the recorder does with a key pressed while it listens. The view and its event monitor are checked by hand.
@Suite("Hotkey recorder")
struct HotkeyRecorderTests {
    private let command: UInt = 1 << 20
    private let control: UInt = 1 << 18
    private let shift: UInt = 1 << 17
    private let function: UInt = 1 << 23
    private let numericPad: UInt = 1 << 21

    @Test func escapeCancels() {
        #expect(RecorderOutcome.forKeyDown(keyCode: KeyCode.escape, cocoaFlags: 0) == .cancel)
    }

    @Test func deleteClears() {
        #expect(RecorderOutcome.forKeyDown(keyCode: KeyCode.delete, cocoaFlags: 0) == .clear)
    }

    @Test func forwardDeleteClearsAndItsFnFlagIsNotAModifier() {
        // The Forward Delete key (and the arrows, Home and End) report Fn without it being held.
        #expect(RecorderOutcome.forKeyDown(keyCode: KeyCode.forwardDelete, cocoaFlags: function) == .clear)
        #expect(RecorderOutcome.forKeyDown(keyCode: KeyCode.forwardDelete, cocoaFlags: function | numericPad) == .clear)
    }

    @Test func escapeAndDeleteWithAModifierAreCombosLikeAnyOther() {
        #expect(RecorderOutcome.forKeyDown(keyCode: KeyCode.escape, cocoaFlags: command)
            == .record(KeyCombo(keyCode: KeyCode.escape, modifiers: .command)))
        #expect(RecorderOutcome.forKeyDown(keyCode: KeyCode.delete, cocoaFlags: command | shift)
            == .record(KeyCombo(keyCode: KeyCode.delete, modifiers: [.command, .shift])))
    }

    @Test func anythingElseSetsTheCombo() {
        #expect(RecorderOutcome.forKeyDown(keyCode: KeyCode.k, cocoaFlags: command | control)
            == .record(KeyCombo(keyCode: KeyCode.k, modifiers: [.command, .control])))
        #expect(RecorderOutcome.forKeyDown(keyCode: KeyCode.space, cocoaFlags: control)
            == .record(KeyCombo(keyCode: KeyCode.space, modifiers: .control)))
        #expect(RecorderOutcome.forKeyDown(keyCode: KeyCode.f5, cocoaFlags: 0)
            == .record(KeyCombo(keyCode: KeyCode.f5, modifiers: [])))
    }

    @Test func aBareLetterIsRecordedAndLeftToTheCheckThatRefusesIt() {
        // The recorder reports it; ClashDetector says `.noModifier`, and the pane doesn't save it.
        #expect(RecorderOutcome.forKeyDown(keyCode: KeyCode.k, cocoaFlags: 0)
            == .record(KeyCombo(keyCode: KeyCode.k, modifiers: [])))
    }

    @Test func fnHeldWithAnotherModifierIsRecordedAsHeard() {
        // Dropping Fn is for registering and showing; what was pressed is what is reported.
        #expect(RecorderOutcome.forKeyDown(keyCode: KeyCode.k, cocoaFlags: command | function)
            == .record(KeyCombo(keyCode: KeyCode.k, modifiers: [.command, .function])))
    }

    @Test func capsLockAndTheNumericPadAreNotModifiers() {
        let capsLock: UInt = 1 << 16
        #expect(RecorderOutcome.forKeyDown(keyCode: KeyCode.leftArrow, cocoaFlags: control | function | numericPad | capsLock)
            == .record(KeyCombo(keyCode: KeyCode.leftArrow, modifiers: [.control, .function])))
    }
}
