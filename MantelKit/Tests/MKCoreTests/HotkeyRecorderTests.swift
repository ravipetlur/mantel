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

/// What the recorder says while it listens.
@Suite("Recorder copy")
struct RecorderCopyTests {
    @Test func theAnnouncementNamesTheActionAndTheKeys() {
        let text = RecorderCopy.announcement(for: "Show hidden icons")
        #expect(text == "Recording a shortcut for Show hidden icons. Press the new shortcut, Delete to remove it, or Escape to cancel.")
    }

    @Test func aRecordingThatCouldntHearSaysSo() {
        #expect(RecorderCopy.couldntComeToTheFront == "Mantel couldn't come to the front, so no shortcut was recorded.")
        // It is no announcement of a recording: nothing is being recorded.
        #expect(!RecorderCopy.couldntComeToTheFront.hasPrefix("Recording"))
    }

    @Test func everyActionGetsItsOwnAnnouncement() {
        let announcements = Set(HotkeyAction.all.map { RecorderCopy.announcement(for: $0.title) })
        #expect(announcements.count == HotkeyAction.all.count)
        #expect(announcements.allSatisfy { $0.hasPrefix("Recording a shortcut for ") })
    }
}

/// When the hotkeys are put aside for a recording.
@Suite("Recording start")
struct RecordingStartTests {
    @Test func theHotkeysAreAsideAtOnceWhenMantelIsActive() {
        var start = RecordingStart()
        let whenItBegan = start.began(mantelIsActive: true)
        #expect(whenItBegan == .putHotkeysAside)
        #expect(start.hotkeysAreAside)
        #expect(start.isRecording)
    }

    @Test func theHotkeysWaitForMantelToBeActive() {
        var start = RecordingStart()
        let whenItBegan = start.began(mantelIsActive: false)
        #expect(whenItBegan == .nothing)
        #expect(!start.hotkeysAreAside, "nothing is unregistered while the recording can't hear")
        #expect(start.isRecording)
        let whenMantelBecameActive = start.mantelBecameActive()
        #expect(whenMantelBecameActive == .putHotkeysAside)
        #expect(start.hotkeysAreAside)
    }

    @Test func aRecordingThatNeverGetsTheFocusGivesUpWithoutHavingTouchedTheHotkeys() {
        var start = RecordingStart()
        _ = start.began(mantelIsActive: false)
        let afterTheWait = start.waitedLongEnough()
        #expect(afterTheWait == .giveUp)
        #expect(!start.isRecording)
        #expect(!start.hotkeysAreAside)
        // Ending it then has nothing to put back, and Mantel becoming active later starts nothing.
        let hotkeysToPutBack = start.ended()
        #expect(!hotkeysToPutBack)
        let whenMantelBecameActiveLater = start.mantelBecameActive()
        #expect(whenMantelBecameActiveLater == .nothing)
        #expect(!start.hotkeysAreAside)
    }

    @Test func endingARecordingThatWasWaitingPutsNothingBack() {
        var start = RecordingStart()
        _ = start.began(mantelIsActive: false)
        let hotkeysToPutBack = start.ended()
        #expect(!hotkeysToPutBack)
        #expect(!start.isRecording)
        // A late "became active", or the timeout, after it ended is nothing.
        let whenMantelBecameActiveLater = start.mantelBecameActive()
        #expect(whenMantelBecameActiveLater == .nothing)
        let whenTheWaitPassedLater = start.waitedLongEnough()
        #expect(whenTheWaitPassedLater == .nothing)
    }

    @Test func endingARecordingThatListenedPutsTheHotkeysBack() {
        var start = RecordingStart()
        _ = start.began(mantelIsActive: true)
        let hotkeysToPutBack = start.ended()
        #expect(hotkeysToPutBack)
        #expect(!start.isRecording)
        #expect(!start.hotkeysAreAside)
        // And only once.
        let hotkeysToPutBackAgain = start.ended()
        #expect(!hotkeysToPutBackAgain)
    }

    @Test func theTimeoutAfterTheRecordingBeganListeningIsNothing() {
        var start = RecordingStart()
        _ = start.began(mantelIsActive: false)
        _ = start.mantelBecameActive()
        let whenTheWaitPassed = start.waitedLongEnough()
        #expect(whenTheWaitPassed == .nothing)
        #expect(start.hotkeysAreAside, "it is listening: the timeout does not end it")
    }

    @Test func aSecondStartWhileRecordingIsNothing() {
        var start = RecordingStart()
        _ = start.began(mantelIsActive: false)
        let whenItBeganAgain = start.began(mantelIsActive: true)
        #expect(whenItBeganAgain == .nothing)
        #expect(!start.hotkeysAreAside)
    }

    @Test func theWaitIsAboutASecond() {
        #expect(RecordingStart.activationWait == .seconds(1))
    }
}
