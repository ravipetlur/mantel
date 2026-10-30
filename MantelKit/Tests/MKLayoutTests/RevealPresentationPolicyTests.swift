import MKCore
import Testing

@testable import MKLayout

/// How a reveal is shown, where the second bar goes, and whether it takes the keyboard.
@Suite("Reveal presentation policy", .timeLimit(.minutes(1)))
struct RevealPresentationPolicyTests {
    private let triggers: [RevealTrigger] = [.dot, .hover, .emptySpaceClick, .scroll, .hotkey, .secondBarHotkey, .command, .commandDrag]

    @Test func alwaysOpensTheBarForEveryTriggerButTheDrag() {
        for trigger in triggers where trigger != .commandDrag {
            for fits in [false, true] {
                #expect(RevealPresentationPolicy.presentation(opens: .always, trigger: trigger, predictedFits: fits) == .secondBar,
                        "\(trigger), predicted to fit \(fits)")
            }
        }
        // The drag needs the icons on the menu bar.
        #expect(RevealPresentationPolicy.presentation(opens: .always, trigger: .commandDrag, predictedFits: false) == .inline)
    }

    @Test func whenNoRoomFollowsThePrediction() {
        for trigger in triggers where trigger != .commandDrag && trigger != .secondBarHotkey {
            #expect(RevealPresentationPolicy.presentation(opens: .whenNoRoom, trigger: trigger, predictedFits: true) == .inline,
                    "\(trigger) fits")
            #expect(RevealPresentationPolicy.presentation(opens: .whenNoRoom, trigger: trigger, predictedFits: false) == .secondBar,
                    "\(trigger) doesn't fit")
        }
    }

    @Test func secondBarHotkeyAlwaysOpensAtThePointer() {
        for opens in SecondBarOpening.allCases {
            for fits in [false, true] {
                #expect(RevealPresentationPolicy.presentation(opens: opens, trigger: .secondBarHotkey, predictedFits: fits) == .secondBar)
            }
        }
        for position in SecondBarPosition.allCases {
            #expect(RevealPresentationPolicy.anchor(trigger: .secondBarHotkey, position: position) == .pointer)
        }
    }

    @Test func commandDragIsAlwaysInline() {
        for opens in SecondBarOpening.allCases {
            for fits in [false, true] {
                #expect(RevealPresentationPolicy.presentation(opens: opens, trigger: .commandDrag, predictedFits: fits) == .inline)
            }
        }
    }

    @Test func dotAnchorFollowsTheSetting() {
        #expect(RevealPresentationPolicy.anchor(trigger: .dot, position: .underDot) == .underDot)
        #expect(RevealPresentationPolicy.anchor(trigger: .dot, position: .rightAligned) == .rightAligned)
        // Nothing else has a dot that was clicked to go under: the bar is against the right edge, whatever the setting is.
        for trigger in triggers where trigger != .dot && trigger != .secondBarHotkey {
            for position in SecondBarPosition.allCases {
                #expect(RevealPresentationPolicy.anchor(trigger: trigger, position: position) == .rightAligned, "\(trigger), \(position)")
            }
        }
    }

    @Test func hoverAndScrollDontMakeKey() {
        #expect(!RevealPresentationPolicy.makesKey(trigger: .hover))
        #expect(!RevealPresentationPolicy.makesKey(trigger: .scroll))
    }

    @Test func aDragsRevealNeverMakesRoom() {
        // Nothing may take over the menu bar, open the second bar or conceal Shown apps while the mouse is held on an icon.
        #expect(!RevealPresentationPolicy.makesRoom(trigger: .commandDrag))
        for trigger in triggers where trigger != .commandDrag {
            #expect(RevealPresentationPolicy.makesRoom(trigger: trigger), "\(trigger) makes room")
        }
    }

    @Test func commandAndDragDontMakeKey() {
        #expect(!RevealPresentationPolicy.makesKey(trigger: .command))
        #expect(!RevealPresentationPolicy.makesKey(trigger: .commandDrag))
    }

    @Test func clicksAndHotkeysMakeKey() {
        #expect(RevealPresentationPolicy.makesKey(trigger: .dot))
        #expect(RevealPresentationPolicy.makesKey(trigger: .emptySpaceClick))
        #expect(RevealPresentationPolicy.makesKey(trigger: .hotkey))
        #expect(RevealPresentationPolicy.makesKey(trigger: .secondBarHotkey))
    }

    @Test func aSecondBarThatWouldListNothingIsShownOnTheMenuBar() {
        #expect(RevealPresentationPolicy.presentation(.secondBar, secondBarListsSomething: false) == .inline)
        #expect(RevealPresentationPolicy.presentation(.secondBar, secondBarListsSomething: true) == .secondBar)
        #expect(RevealPresentationPolicy.presentation(.inline, secondBarListsSomething: false) == .inline)
        #expect(RevealPresentationPolicy.presentation(.inline, secondBarListsSomething: true) == .inline)
    }
}
