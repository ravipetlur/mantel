import Testing

@testable import MKCore

@Suite("Activation policy reasons", .timeLimit(.minutes(1)))
struct ActivationPolicyReasonsTests {
    @Test func nothingOpenAndNoTakeoverIsAnAccessoryApp() {
        let reasons = ActivationPolicyReasons()
        #expect(reasons.policy == .accessory)
        #expect(!reasons.hasOpenWindow)
    }

    @Test func aWindowMakesMantelAnOrdinaryApp() {
        for window in ActivationPolicyReasons.Window.allCases {
            var reasons = ActivationPolicyReasons()
            #expect(reasons.windowOpened(window) == .regular, "\(window)")
            #expect(reasons.policy == .regular)
            #expect(reasons.hasOpenWindow)
        }
    }

    @Test func aTakeoverMakesMantelAnOrdinaryAppWithoutAWindow() {
        var reasons = ActivationPolicyReasons()
        #expect(reasons.takeoverBegan() == .regular)
        #expect(reasons.policy == .regular)
        #expect(!reasons.hasOpenWindow)
        #expect(reasons.takeoverEnded() == .accessory)
        #expect(reasons.policy == .accessory)
    }

    @Test func closingTheLastWindowGoesBackToAccessory() {
        var reasons = ActivationPolicyReasons()
        reasons.windowOpened(.settings)
        #expect(reasons.windowClosed(.settings) == .accessory)
        #expect(reasons.policy == .accessory)
        #expect(!reasons.hasOpenWindow)

        // And again, after another is opened: the policy is what the reasons say, not a memory of what was set.
        #expect(reasons.windowOpened(.onboarding) == .regular)
        #expect(reasons.windowClosed(.onboarding) == .accessory)
    }

    @Test func twoWindowsCountOnce() {
        var reasons = ActivationPolicyReasons()
        // Settings and onboarding together are one reason to be an ordinary app: the policy changes when the first opens and when the
        // last closes, and at no time in between.
        #expect(reasons.windowOpened(.settings) == .regular)
        #expect(reasons.windowOpened(.onboarding) == nil, "already an ordinary app")
        #expect(reasons.windowClosed(.settings) == nil, "onboarding is still open")
        #expect(reasons.policy == .regular)
        #expect(reasons.windowClosed(.onboarding) == .accessory)

        // The same window shown twice (asked for again while it was open) is one window: one close ends it.
        #expect(reasons.windowOpened(.settings) == .regular)
        #expect(reasons.windowOpened(.settings) == nil)
        #expect(reasons.windowClosed(.settings) == .accessory)
        #expect(reasons.policy == .accessory)
    }

    @Test func closingAWindowThatWasNeverOpenChangesNothing() {
        var reasons = ActivationPolicyReasons()
        #expect(reasons.windowClosed(.settings) == nil)
        #expect(reasons.policy == .accessory)
        reasons.windowOpened(.onboarding)
        #expect(reasons.windowClosed(.settings) == nil, "another window's close isn't this one's")
        #expect(reasons.policy == .regular)
    }

    @Test func aTakeoverEndingWhileSettingsIsOpenKeepsTheDockIcon() {
        var reasons = ActivationPolicyReasons()
        #expect(reasons.takeoverBegan() == .regular)
        #expect(reasons.windowOpened(.settings) == nil, "already an ordinary app, for the takeover")
        #expect(reasons.takeoverEnded() == nil, "Settings is still open")
        #expect(reasons.policy == .regular)
        // Closing Settings is then what makes Mantel a menu bar app again.
        #expect(reasons.windowClosed(.settings) == .accessory)
    }

    @Test func closingSettingsDuringATakeoverLeavesMantelOrdinaryUntilTheTakeoverEnds() {
        var reasons = ActivationPolicyReasons()
        #expect(reasons.windowOpened(.settings) == .regular)
        #expect(reasons.takeoverBegan() == nil)
        #expect(reasons.windowClosed(.settings) == nil, "the takeover still needs the menu bar")
        #expect(reasons.policy == .regular)
        #expect(reasons.takeoverEnded() == .accessory)
        #expect(reasons.policy == .accessory)
    }

    @Test func aTakeoverBegunAndEndedTwiceIsOneReason() {
        var reasons = ActivationPolicyReasons()
        #expect(reasons.takeoverBegan() == .regular)
        #expect(reasons.takeoverBegan() == nil)
        #expect(reasons.takeoverEnded() == .accessory)
        #expect(reasons.takeoverEnded() == nil)
    }

    // MARK: Giving the focus back

    @Test func aTakeoverHandsTheFocusBackWhenItIsAskedTo() {
        for windowIsOpen in [false, true] {
            #expect(ActivationPolicyReasons.takeoverHandsBackFocus(requested: true, personUsedAMantelWindow: false, aWindowIsOpen: windowIsOpen))
            // Another app came to the front by itself: the focus is where the person put it.
            #expect(!ActivationPolicyReasons.takeoverHandsBackFocus(requested: false, personUsedAMantelWindow: false, aWindowIsOpen: windowIsOpen))
            #expect(!ActivationPolicyReasons.takeoverHandsBackFocus(requested: false, personUsedAMantelWindow: true, aWindowIsOpen: windowIsOpen))
        }
    }

    @Test func aTakeoverThatBroughtSettingsForwardStillHandsTheFocusBack() {
        // Settings is open behind Safari. The takeover brings Mantel forward, and Settings with it, and makes it key: nobody did anything in
        // it, so the focus goes back to Safari when the reveal is put away.
        var reasons = ActivationPolicyReasons()
        reasons.windowOpened(.settings)
        reasons.takeoverBegan()
        #expect(!reasons.personUsedAWindowDuringTakeover)
        let used = reasons.personUsedAWindowDuringTakeover
        reasons.takeoverEnded()
        #expect(ActivationPolicyReasons.takeoverHandsBackFocus(requested: true, personUsedAMantelWindow: used, aWindowIsOpen: reasons.hasOpenWindow))
        #expect(reasons.policy == .regular, "Settings is still open: the Dock icon stays")
    }

    @Test func clickingIntoSettingsDuringATakeoverKeepsTheFocus() {
        var reasons = ActivationPolicyReasons()
        reasons.windowOpened(.settings)
        reasons.takeoverBegan()
        // The person clicked in the Settings window.
        reasons.personUsedAMantelWindow()
        #expect(reasons.personUsedAWindowDuringTakeover)
        let used = reasons.personUsedAWindowDuringTakeover
        reasons.takeoverEnded()
        #expect(!ActivationPolicyReasons.takeoverHandsBackFocus(requested: true, personUsedAMantelWindow: used, aWindowIsOpen: reasons.hasOpenWindow))
    }

    @Test func aWindowUsedAndClosedDuringATakeoverStillHandsTheFocusBack() {
        // Settings is open behind Safari, the takeover brings it forward, the person uses it and closes it (⌘W) before the takeover ends:
        // there is no window left to be in, so the focus goes back to Safari.
        var reasons = ActivationPolicyReasons()
        reasons.windowOpened(.settings)
        reasons.takeoverBegan()
        reasons.personUsedAMantelWindow()
        reasons.windowClosed(.settings)
        #expect(reasons.policy == .regular, "the takeover still holds")
        let used = reasons.personUsedAWindowDuringTakeover
        #expect(used)
        reasons.takeoverEnded()
        #expect(!reasons.hasOpenWindow)
        #expect(ActivationPolicyReasons.takeoverHandsBackFocus(requested: true, personUsedAMantelWindow: used, aWindowIsOpen: reasons.hasOpenWindow))
        #expect(ActivationPolicyReasons.focusAfterTakeover(requested: true, personUsedAMantelWindow: used, aWindowIsOpen: reasons.hasOpenWindow,
                                                           hasAppToHandBackTo: true, mantelIsActive: true) == .handBack)

        // Settings… chosen during the takeover and closed again before it ends is the same: asking for a window counts as use.
        var asked = ActivationPolicyReasons()
        asked.takeoverBegan()
        asked.windowOpened(.settings)
        asked.windowClosed(.settings)
        let askedFor = asked.personUsedAWindowDuringTakeover
        asked.takeoverEnded()
        #expect(askedFor)
        #expect(ActivationPolicyReasons.takeoverHandsBackFocus(requested: true, personUsedAMantelWindow: askedFor, aWindowIsOpen: asked.hasOpenWindow))
    }

    /// Where the focus goes when a takeover ends: kept when a window is still open (with Mantel in front and no app to go back to, too) or
    /// when another app came forward and Mantel isn't active; given up when Mantel was in front at the beginning and no window is open.
    @Test(arguments: [
        (requested: true, used: true, windowOpen: true, hasApp: true, active: true, focus: ActivationPolicyReasons.FocusAfterTakeover.keep),
        (requested: true, used: false, windowOpen: false, hasApp: false, active: true, focus: .deactivate),
        (requested: false, used: false, windowOpen: false, hasApp: true, active: false, focus: .keep),
        (requested: true, used: true, windowOpen: false, hasApp: false, active: false, focus: .keep),
        (requested: true, used: false, windowOpen: true, hasApp: false, active: true, focus: .keep),
    ])
    func theFocusAfterATakeoverGoesWhereItBelongs(requested: Bool, used: Bool, windowOpen: Bool, hasApp: Bool, active: Bool,
                                                  focus: ActivationPolicyReasons.FocusAfterTakeover) {
        #expect(ActivationPolicyReasons.focusAfterTakeover(requested: requested, personUsedAMantelWindow: used, aWindowIsOpen: windowOpen,
                                                           hasAppToHandBackTo: hasApp, mantelIsActive: active) == focus)
    }

    @Test func aTakeoverEndingWithNoWindowNeverLeavesMantelActive() {
        // Whatever was asked, used or remembered: with no window open Mantel is a menu bar app again, and if it were still the active app
        // the keys would go nowhere. Either the focus goes back, or Mantel gives it up.
        for requested in [false, true] {
            for used in [false, true] {
                for hasApp in [false, true] {
                    let focus = ActivationPolicyReasons.focusAfterTakeover(requested: requested, personUsedAMantelWindow: used, aWindowIsOpen: false,
                                                                           hasAppToHandBackTo: hasApp, mantelIsActive: true)
                    #expect(focus == .handBack || focus == .deactivate,
                            "requested \(requested), used \(used), app to give it to \(hasApp): \(focus)")
                    // An app to give it to, and asked to: it is the one that gets it.
                    #expect((focus == .handBack) == (requested && hasApp), "requested \(requested), used \(used), app \(hasApp)")
                }
            }
        }
    }

    @Test func askingForAWindowDuringATakeoverCountsAsUsingIt() {
        // Settings… chosen from the dots' menu while icons are revealed: even if Settings was open already, the person asked for it.
        for alreadyOpen in [false, true] {
            var reasons = ActivationPolicyReasons()
            if alreadyOpen { reasons.windowOpened(.settings) }
            reasons.takeoverBegan()
            #expect(!reasons.personUsedAWindowDuringTakeover)
            reasons.windowOpened(.settings)
            #expect(reasons.personUsedAWindowDuringTakeover, "already open: \(alreadyOpen)")
        }
    }

    @Test func useOutsideATakeoverIsNotNoted() {
        var reasons = ActivationPolicyReasons()
        reasons.windowOpened(.settings)
        reasons.personUsedAMantelWindow()
        #expect(!reasons.personUsedAWindowDuringTakeover)
        // Nor does what happened before a takeover carry into it, or a takeover into the next.
        reasons.takeoverBegan()
        #expect(!reasons.personUsedAWindowDuringTakeover)
        reasons.personUsedAMantelWindow()
        reasons.takeoverEnded()
        reasons.takeoverBegan()
        #expect(!reasons.personUsedAWindowDuringTakeover, "a new takeover starts clean")
        // The same takeover begun again while it lasts is still the one.
        reasons.personUsedAMantelWindow()
        reasons.takeoverBegan()
        #expect(reasons.personUsedAWindowDuringTakeover)
    }

    // MARK: The main menu

    @Test func aWindowGetsTheFullMenu() {
        #expect(ActivationPolicyReasons().menuKind == .none, "a menu bar app has no menu")
        for window in ActivationPolicyReasons.Window.allCases {
            var reasons = ActivationPolicyReasons()
            reasons.windowOpened(window)
            #expect(reasons.menuKind == .full, "\(window)")
            // And with a takeover on top: the window needs it all the same.
            reasons.takeoverBegan()
            #expect(reasons.menuKind == .full, "\(window), during a takeover")
        }
    }

    @Test func aTakeoverAloneGetsOnlyTheAppMenu() {
        var reasons = ActivationPolicyReasons()
        reasons.takeoverBegan()
        #expect(reasons.menuKind == .appOnly, "short, so that the room on the bar is there for the icons")
        reasons.takeoverEnded()
        #expect(reasons.menuKind == .none)
    }

    @Test func settingsOpeningDuringATakeoverChangesTheMenu() {
        var reasons = ActivationPolicyReasons()
        reasons.takeoverBegan()
        #expect(reasons.menuKind == .appOnly)
        // The policy doesn't change (Mantel is an ordinary app already), but the menu has to.
        #expect(reasons.windowOpened(.settings) == nil)
        #expect(reasons.menuKind == .full)
        // And it goes short again when the window closes, while the takeover lasts, and away when that ends.
        #expect(reasons.windowClosed(.settings) == nil)
        #expect(reasons.menuKind == .appOnly)
        #expect(reasons.takeoverEnded() == .accessory)
        #expect(reasons.menuKind == .none)
    }

    /// Closing the last window of an active Mantel lets the next app have the focus; a close that leaves Mantel an ordinary app changes no
    /// one's focus.
    @Test(arguments: [
        (change: ActivationPolicyKind?.some(.accessory), active: true, handsBack: true),
        (change: .some(.accessory), active: false, handsBack: false),
        (change: nil, active: true, handsBack: false),
        (change: .some(.regular), active: true, handsBack: false),
    ])
    func closingHandsBackTheFocusOnlyWhenMantelBecomesAnAccessoryWhileActive(change: ActivationPolicyKind?, active: Bool, handsBack: Bool) {
        #expect(ActivationPolicyReasons.closingHandsBackFocus(policyChange: change, mantelIsActive: active) == handsBack)
    }
}
