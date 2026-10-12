import CoreGraphics
import Foundation
import Testing

@testable import MKMenuBar

/// What the system click tap does with each input, as plain values. The tap itself, which needs a live event stream, has no test:
/// nothing here installs one.
@Suite("System click policy", .timeLimit(.minutes(1)))
struct SystemClickPolicyTests {
    private let clock = CGRect(x: 3268, y: 0, width: 80, height: 30)
    private let portraitClock = CGRect(x: -92, y: -491, width: 80, height: 30)
    private let inside = CGPoint(x: 3300, y: 10)
    private let fnFlag = CGEventFlags.maskSecondaryFn
    private let n = SystemClickPolicy.replayKeyCode

    private func decide(_ policy: inout SystemClickPolicy, _ input: SystemInput, at point: CGPoint? = nil, keyCode: UInt16? = nil,
                        flags: CGEventFlags = [], isOurs: Bool = false, armed: Bool = true, rects: [CGRect]? = nil) -> ClickDecision {
        policy.decide(input, at: point ?? inside, keyCode: keyCode, flags: flags, isOurs: isOurs, armed: armed, rects: rects ?? [clock])
    }

    private func evaluate(_ policy: inout SystemClickPolicy, _ input: SystemInput, at point: CGPoint? = nil, keyCode: UInt16? = nil,
                          flags: CGEventFlags = [], isRepeat: Bool = false, isOurs: Bool = false, armed: Bool = true,
                          rects: [CGRect]? = nil) -> SystemClickVerdict {
        policy.evaluate(input, at: point ?? inside, keyCode: keyCode, flags: flags, isRepeat: isRepeat, isOurs: isOurs, armed: armed,
                        rects: rects ?? [clock])
    }

    // MARK: Clicks

    @Test func leftAndRightDownInsideAreSwallowed() {
        var policy = SystemClickPolicy()
        #expect(decide(&policy, .mouseDown(left: true)) == .swallow)
        #expect(decide(&policy, .mouseUp(left: true)) == .swallow)
        #expect(decide(&policy, .mouseDown(left: false)) == .swallow)
        #expect(decide(&policy, .mouseUp(left: false)) == .swallow)
    }

    @Test func upAndDragOfSwallowedClickAreSwallowed() {
        var policy = SystemClickPolicy()
        #expect(decide(&policy, .mouseDown(left: true)) == .swallow)
        // The pointer may have moved off the item before the button came up.
        #expect(decide(&policy, .mouseDragged(left: true), at: CGPoint(x: 3000, y: 10)) == .swallow)
        #expect(decide(&policy, .mouseDragged(left: true), at: CGPoint(x: 100, y: 400)) == .swallow)
        #expect(decide(&policy, .mouseUp(left: true), at: CGPoint(x: 100, y: 400)) == .swallow)
        // And once it has, the next up and the next drag are ordinary ones.
        #expect(decide(&policy, .mouseUp(left: true)) == .pass)
        #expect(decide(&policy, .mouseDragged(left: true)) == .pass)
    }

    @Test func eachButtonIsSwallowedOnItsOwn() {
        var policy = SystemClickPolicy()
        #expect(decide(&policy, .mouseDown(left: true)) == .swallow)
        // The right button's up, with no right down before it, is not the left click's.
        #expect(decide(&policy, .mouseUp(left: false)) == .pass)
        #expect(decide(&policy, .mouseDragged(left: false)) == .pass)
        #expect(decide(&policy, .mouseUp(left: true)) == .swallow)
    }

    @Test func outsidePasses() {
        var policy = SystemClickPolicy()
        #expect(decide(&policy, .mouseDown(left: true), at: CGPoint(x: 500, y: 10)) == .pass)
        #expect(decide(&policy, .mouseDown(left: false), at: CGPoint(x: 500, y: 10)) == .pass)
        #expect(decide(&policy, .mouseDown(left: true), at: CGPoint(x: 3300, y: 400)) == .pass, "below the bar")
        // An up and a drag of a click that wasn't swallowed pass, over the target too.
        _ = decide(&policy, .mouseDown(left: true), at: CGPoint(x: 500, y: 10))
        #expect(decide(&policy, .mouseDragged(left: true), at: inside) == .pass)
        #expect(decide(&policy, .mouseUp(left: true), at: inside) == .pass)
    }

    @Test func aTargetOnAnotherDisplayHoldsToo() {
        var policy = SystemClickPolicy()
        let rects = [portraitClock, clock]
        #expect(decide(&policy, .mouseDown(left: true), at: CGPoint(x: -50, y: -480), rects: rects) == .swallow)
        _ = decide(&policy, .mouseUp(left: true), rects: rects)
        #expect(decide(&policy, .mouseDown(left: true), at: inside, rects: rects) == .swallow)
    }

    @Test func noTargetsSwallowNothing() {
        var policy = SystemClickPolicy()
        #expect(decide(&policy, .mouseDown(left: true), rects: []) == .pass)
        #expect(decide(&policy, .keyDown, keyCode: n, flags: fnFlag, rects: []) == .swallow, "the shortcut has no place, so no targets matter to it")
    }

    @Test func aTargetIsHalfOpenSoNeighboursDontShareAnEdge() {
        var policy = SystemClickPolicy()
        #expect(decide(&policy, .mouseDown(left: true), at: CGPoint(x: 3268, y: 0)) == .swallow, "its own left and top edge")
        _ = decide(&policy, .mouseUp(left: true))
        #expect(decide(&policy, .mouseDown(left: true), at: CGPoint(x: 3348, y: 10)) == .pass, "its right edge belongs to the next item")
    }

    @Test func notArmedPassesEverything() {
        var policy = SystemClickPolicy()
        // The allowlist has been lifted for a click, or there is none: a second click on the clock goes straight through.
        #expect(decide(&policy, .mouseDown(left: true), armed: false) == .pass)
        #expect(decide(&policy, .mouseDragged(left: true), armed: false) == .pass)
        #expect(decide(&policy, .mouseUp(left: true), armed: false) == .pass)
        #expect(decide(&policy, .mouseDown(left: false), armed: false) == .pass)
        #expect(decide(&policy, .mouseUp(left: false), armed: false) == .pass)
        #expect(decide(&policy, .keyDown, keyCode: n, flags: fnFlag, armed: false) == .pass)
        #expect(decide(&policy, .keyUp, keyCode: n, flags: fnFlag, armed: false) == .pass)
    }

    @Test func ownPostsPass() {
        var policy = SystemClickPolicy()
        // Inside a target and armed, but the tap's own: swallowing it would swallow the replay, and replay it for ever.
        #expect(decide(&policy, .mouseDown(left: true), isOurs: true) == .pass)
        #expect(decide(&policy, .mouseUp(left: true), isOurs: true) == .pass)
        #expect(decide(&policy, .mouseDown(left: false), isOurs: true) == .pass)
        #expect(decide(&policy, .keyDown, keyCode: n, flags: fnFlag, isOurs: true) == .pass)
        #expect(decide(&policy, .keyUp, keyCode: n, flags: fnFlag, isOurs: true) == .pass)
        // And they don't disturb a click that is being swallowed.
        _ = decide(&policy, .mouseDown(left: true))
        #expect(decide(&policy, .mouseUp(left: true), isOurs: true) == .pass)
        #expect(decide(&policy, .mouseUp(left: true)) == .swallow)
        // Nor a key.
        _ = decide(&policy, .keyDown, keyCode: n, flags: fnFlag)
        #expect(decide(&policy, .keyUp, keyCode: n, flags: fnFlag, isOurs: true) == .pass)
        #expect(decide(&policy, .keyUp, keyCode: n, flags: fnFlag) == .swallow)
    }

    @Test func aDownStartsAfreshWhateverTheOneBeforeDid() {
        var policy = SystemClickPolicy()
        // A swallowed click whose up was lost (the system switched the tap off for a moment) doesn't make the next one swallowed.
        _ = decide(&policy, .mouseDown(left: true))
        #expect(decide(&policy, .mouseDown(left: true), at: CGPoint(x: 500, y: 10)) == .pass)
        #expect(decide(&policy, .mouseUp(left: true), at: CGPoint(x: 500, y: 10)) == .pass)
    }

    // MARK: Fn+N

    @Test func fnNIsSwallowedWhenArmed() {
        var policy = SystemClickPolicy()
        #expect(decide(&policy, .keyDown, keyCode: n, flags: fnFlag) == .swallow)
        // Whether the pointer is anywhere near a target or not.
        #expect(decide(&policy, .keyUp, keyCode: n, flags: fnFlag, rects: []) == .swallow)
    }

    @Test func fnNIsKeyCode45() {
        #expect(SystemClickPolicy.replayKeyCode == 45)
    }

    @Test func commandFnNPasses() {
        for other in [CGEventFlags.maskCommand, .maskControl, .maskAlternate, .maskShift,
                      [.maskCommand, .maskShift], [.maskControl, .maskAlternate, .maskShift, .maskCommand]] {
            var policy = SystemClickPolicy()
            #expect(decide(&policy, .keyDown, keyCode: n, flags: fnFlag.union(other)) == .pass, "\(other.rawValue)")
            #expect(decide(&policy, .keyUp, keyCode: n, flags: fnFlag.union(other)) == .pass)
        }
    }

    @Test func plainNPasses() {
        var policy = SystemClickPolicy()
        #expect(decide(&policy, .keyDown, keyCode: n, flags: []) == .pass, "typing the letter")
        #expect(decide(&policy, .keyUp, keyCode: n, flags: []) == .pass)
        // Caps Lock and the numeric-pad bit are not other shortcuts' modifiers.
        #expect(decide(&policy, .keyDown, keyCode: n, flags: [.maskAlphaShift]) == .pass, "without Fn")
        #expect(decide(&policy, .keyDown, keyCode: n, flags: [.maskSecondaryFn, .maskAlphaShift]) == .swallow, "Caps Lock isn't another shortcut")
    }

    @Test func keyUpOfSwallowedKeyIsSwallowed() {
        var policy = SystemClickPolicy()
        #expect(decide(&policy, .keyDown, keyCode: n, flags: fnFlag) == .swallow)
        // Fn can be let go of first, so the up comes with no flags at all.
        #expect(decide(&policy, .keyUp, keyCode: n, flags: []) == .swallow)
        // And the next up of N is an ordinary one.
        #expect(decide(&policy, .keyUp, keyCode: n, flags: []) == .pass)
    }

    @Test func anotherKeyIsNeverHeldEvenWithFn() {
        // The Fn flag is set for the arrow and function keys on some keyboards.
        var policy = SystemClickPolicy()
        for code: UInt16 in [123, 124, 125, 126, 122, 120, 0, 44, 46] {
            #expect(decide(&policy, .keyDown, keyCode: code, flags: fnFlag) == .pass, "key \(code)")
            #expect(decide(&policy, .keyUp, keyCode: code, flags: fnFlag) == .pass)
        }
        #expect(decide(&policy, .keyDown, keyCode: nil, flags: fnFlag) == .pass, "no key code")
    }

    @Test func anotherKeyPressedWhileTheHeldOneIsDownDoesNotEndTheHold() {
        var policy = SystemClickPolicy()
        _ = decide(&policy, .keyDown, keyCode: n, flags: fnFlag)
        #expect(decide(&policy, .keyDown, keyCode: 46, flags: fnFlag) == .pass)
        #expect(decide(&policy, .keyUp, keyCode: 46, flags: fnFlag) == .pass)
        #expect(decide(&policy, .keyUp, keyCode: n, flags: []) == .swallow, "the up of the held key is still its own")
    }

    @Test func autoRepeatOfTheHeldKeyIsSwallowedAndHeldOnlyOnce() {
        var policy = SystemClickPolicy()
        let first = evaluate(&policy, .keyDown, keyCode: n, flags: fnFlag)
        #expect(first.decision == .swallow)
        #expect(first.startsHold)
        // Once the allowlist has been lifted nothing is armed, and the key that is still down goes on repeating.
        for _ in 0..<3 {
            let again = evaluate(&policy, .keyDown, keyCode: n, flags: fnFlag, isRepeat: true, armed: false)
            #expect(again.decision == .swallow)
            #expect(!again.startsHold, "one hold for the whole press")
        }
        #expect(evaluate(&policy, .keyUp, keyCode: n, flags: []).decision == .swallow)
        // A repeat of a key that was not held is not ours.
        #expect(evaluate(&policy, .keyDown, keyCode: n, flags: [], isRepeat: true).decision == .pass)
    }

    @Test func aNewPressOfNAfterALostUpIsJudgedOnItsOwn() {
        var policy = SystemClickPolicy()
        _ = decide(&policy, .keyDown, keyCode: n, flags: fnFlag)
        // The up never came. Typing the letter afterwards is typing, not a repeat of a held key.
        #expect(decide(&policy, .keyDown, keyCode: n, flags: [], armed: false) == .pass)
        #expect(decide(&policy, .keyUp, keyCode: n, flags: []) == .pass)
    }

    // MARK: What the tap is told

    @Test func aSwallowedDownStartsAHoldAndNothingElseDoes() {
        var policy = SystemClickPolicy()
        let down = evaluate(&policy, .mouseDown(left: true))
        #expect(down == SystemClickVerdict(decision: .swallow, startsHold: true, isClickOutside: false))
        #expect(evaluate(&policy, .mouseDragged(left: true)) == SystemClickVerdict(decision: .swallow))
        #expect(evaluate(&policy, .mouseUp(left: true)) == SystemClickVerdict(decision: .swallow))
        #expect(evaluate(&policy, .keyDown, keyCode: n, flags: fnFlag).startsHold)
        #expect(!evaluate(&policy, .keyUp, keyCode: n, flags: fnFlag).startsHold)
    }

    @Test func aDownOutsideWhileNotArmedIsAClickOutside() {
        var policy = SystemClickPolicy()
        let away = CGPoint(x: 500, y: 400)
        let outside = evaluate(&policy, .mouseDown(left: true), at: away, armed: false)
        #expect(outside.decision == .pass)
        #expect(outside.isClickOutside)
        #expect(!outside.startsHold)
        // Either button.
        #expect(evaluate(&policy, .mouseDown(left: false), at: away, armed: false).isClickOutside)
    }

    @Test func otherInputsAreNotAClickOutside() {
        var policy = SystemClickPolicy()
        let away = CGPoint(x: 500, y: 400)
        // Armed: nothing is lifted, so there is no panel to click away from.
        #expect(!evaluate(&policy, .mouseDown(left: true), at: away, armed: true).isClickOutside)
        // On a target while lifted: the clock is clicked again, which is not clicking away.
        #expect(!evaluate(&policy, .mouseDown(left: true), at: inside, armed: false).isClickOutside)
        // Only a down is a click.
        #expect(!evaluate(&policy, .mouseUp(left: true), at: away, armed: false).isClickOutside)
        #expect(!evaluate(&policy, .mouseDragged(left: true), at: away, armed: false).isClickOutside)
        #expect(!evaluate(&policy, .keyDown, keyCode: n, flags: fnFlag, armed: false).isClickOutside)
        // And not our own.
        #expect(!evaluate(&policy, .mouseDown(left: true), at: away, isOurs: true, armed: false).isClickOutside)
    }

    @Test func theInputsThatCanStartAHold() {
        #expect(SystemInput.mouseDown(left: true).canStartHold)
        #expect(SystemInput.mouseDown(left: false).canStartHold)
        #expect(SystemInput.keyDown.canStartHold)
        #expect(!SystemInput.mouseUp(left: true).canStartHold)
        #expect(!SystemInput.mouseDragged(left: false).canStartHold)
        #expect(!SystemInput.keyUp.canStartHold)
        #expect(SystemInput.keyDown.isKey)
        #expect(SystemInput.keyUp.isKey)
        #expect(!SystemInput.mouseDown(left: true).isKey)
    }
}
