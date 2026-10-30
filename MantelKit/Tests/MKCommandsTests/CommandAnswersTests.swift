import MKCommands
import MKCore
import Testing

@Suite("Command answers", .timeLimit(.minutes(2)))
struct CommandAnswersTests {
    @Test func showSaysWhatWasDone() {
        #expect(CommandAnswers.show(.hidden) == "Showing hidden icons.")
        #expect(CommandAnswers.show(.all) == "Showing all icons.")
        #expect(CommandAnswers.show(.nothing) == "Hiding icons again.")
    }

    @Test func focusSaysHowItIsNow() {
        #expect(CommandAnswers.focus(isOn: true) == "Focus Mode is on.")
        #expect(CommandAnswers.focus(isOn: false) == "Focus Mode is off.")
    }

    @Test func refreshAndStartingHaveTheirWords() {
        #expect(CommandAnswers.refreshed == "Menu bar refreshed.")
        #expect(CommandAnswers.stillStarting == "Mantel is still starting. Try again in a moment.")
    }

    @Test func resetSaysWhatCameOfIt() {
        #expect(CommandAnswers.reset == "Menu bar reset.")
        #expect(CommandAnswers.resetUnderWay == "A reset is already under way.")
        #expect(ResetOutcome.done.result == .ok(.string("Menu bar reset.")))
        #expect(ResetOutcome.alreadyUnderWay.result == .failure(code: .unavailable, message: "A reset is already under way."))
        let words = "macOS's menu bar didn't restart. Log out and back in to restart it."
        #expect(ResetOutcome.failed(words).result == .failure(code: .failed, message: words))
        #expect(ResetOutcome.done.message == "Menu bar reset.")
        #expect(ResetOutcome.alreadyUnderWay.message == "A reset is already under way.")
        #expect(ResetOutcome.failed(words).message == words)
    }

    @Test func aResetThatWasNotStartedIsRefusedNotFailed() {
        // Nothing was changed: it is unavailable now, the way a second reset is, and the sentence is what the person is told.
        let words = ReplayNowPolicy.probeChangingMenuBarText
        #expect(ResetOutcome.refused(words).result == .failure(code: .unavailable, message: words))
        #expect(ResetOutcome.refused(words).message == words)
        #expect(ResetOutcome.refused(CommandAnswers.quitting).result == .failure(code: .unavailable, message: "Mantel is quitting."))
        #expect(CommandAnswers.quitting == "Mantel is quitting.")
    }

    @Test func aRefreshSaysItWasDoneOrWhyItWasNot() {
        #expect(RefreshOutcome.done.result == .ok(.string("Menu bar refreshed.")))
        #expect(RefreshOutcome.done.message == "Menu bar refreshed.")
        // Asked during a reset, it didn't refresh anything, and it doesn't say it did.
        let refused = RefreshOutcome.refused(CommandAnswers.resetUnderWay)
        #expect(refused.result == .failure(code: .unavailable, message: "A reset is already under way."))
        #expect(refused.message == "A reset is already under way.")
    }

    @Test func everyAnswerIsASentence() {
        let answers = ShowTarget.allCases.map(CommandAnswers.show) + [CommandAnswers.focus(isOn: true), CommandAnswers.focus(isOn: false),
                                                                      CommandAnswers.refreshed, CommandAnswers.stillStarting,
                                                                      CommandAnswers.reset, CommandAnswers.resetUnderWay, CommandAnswers.quitting]
        for answer in answers {
            #expect(answer.hasSuffix("."), "\(answer)")
            #expect(answer.first?.isUppercase == true, "\(answer)")
        }
    }

    // MARK: Icons, the bar, the pictures and the order

    @Test func iconShowAndClickSayWhatWasDone() {
        #expect(CommandAnswers.iconShown(app: "Notes") == "Showing Notes.")
        #expect(CommandAnswers.iconClicked(app: "Notes", kind: .left) == "Clicked Notes.")
        #expect(CommandAnswers.iconClicked(app: "Notes", kind: .right) == "Clicked Notes.")
        // An option click arrives as a plain click, and the answer says so.
        #expect(CommandAnswers.iconClicked(app: "Notes", kind: .option) == "Clicked Notes as a left click.")
    }

    @Test func eachClickFailureHasItsSentence() {
        #expect(CommandAnswers.iconNoRoom(app: "Notes") == "There's no room on the menu bar to click Notes.")
        #expect(CommandAnswers.iconBarHidden(app: "Notes", kind: .right)
                == "The menu bar is hidden by a full-screen app, so Notes can't be right-clicked.")
        #expect(CommandAnswers.iconBarHidden(app: "Notes", kind: .option)
                == "The menu bar is hidden by a full-screen app, so Notes can't be option-clicked.")
        #expect(CommandAnswers.iconRefused(app: "Notes", text: "it was busy") == "Notes didn't respond to the click: it was busy")
        #expect(CommandAnswers.iconNotRunning(app: "Notes") == "Notes isn't running.")
        #expect(CommandAnswers.iconUnreachable(app: "Notes") == "Mantel couldn't reach Notes's icon.")
        #expect(CommandAnswers.iconOvertaken(app: "Notes") == "Notes's icon wasn't clicked: another click came first.")
    }

    @Test func theBarSaysWhetherItIsOpen() {
        #expect(CommandAnswers.bar(isOpen: true) == "The second bar is open.")
        #expect(CommandAnswers.bar(isOpen: false) == "The second bar is closed.")
    }

    @Test func recaptureSaysHowManyOrWhyNot() {
        #expect(CommandAnswers.recapture(captured: 7, skipped: nil) == .ok(.string("Captured 7 icons.")))
        #expect(CommandAnswers.recapture(captured: 1, skipped: nil) == .ok(.string("Captured 1 icon.")))
        #expect(CommandAnswers.recapture(captured: 0, skipped: CommandAnswers.screenRecordingOffReason)
                == .failure(code: .unavailable, message: "Screen Recording is off for Mantel, so app icons stand in. Turn it on in Settings › Permissions."))
        // Any other reason is the skip's own words.
        // ... with a full stop at the end, which the collector's reasons don't have and the layout's already do.
        #expect(CommandAnswers.recapture(captured: 0, skipped: "The bar was captured a moment ago")
                == .failure(code: .unavailable, message: "The bar was captured a moment ago."))
        #expect(CommandAnswers.recapture(captured: 0, skipped: CommandAnswers.resetUnderWay)
                == .failure(code: .unavailable, message: "A reset is already under way."))
    }

    @Test func layoutRestoreHasItsSentences() {
        #expect(CommandAnswers.layoutRestored == "The menu bar order is back to how it was.")
        #expect(CommandAnswers.layoutNothingToRestore == "Nothing to put back: Mantel hasn't changed the order.")
        #expect(CommandAnswers.layoutNeedsGrant == "Grant access to the layout file in Settings › Layout first.")
        #expect(CommandAnswers.layoutRestoreFailed("macOS didn't take it.") == "Couldn't change the menu bar order: macOS didn't take it.")
    }

    @Test func theIconListHasOneObjectPerIconWithTheNamedKeys() {
        let rows = [
            IconListRow(id: "com.example.a::main", app: "com.example.a", name: "Alpha", section: .shown, group: nil, image: "/tmp/a.png"),
            IconListRow(id: "com.example.b#0", app: "com.example.b", name: "Beta", section: .always, group: nil, image: nil),
            IconListRow(id: "system:wifi", app: "com.apple.menuextra", name: "Wi-Fi", section: nil, group: "Network", image: nil),
            IconListRow(id: "com.example.c#1", app: "com.example.c", name: "Gamma", section: .hidden, group: nil, image: nil),
        ]
        guard case .array(let all) = CommandAnswers.iconList(rows, filter: nil) else {
            Issue.record("expected an array")
            return
        }
        #expect(all.count == 4)
        #expect(all[0] == .object(["id": .string("com.example.a::main"), "app": .string("com.example.a"), "name": .string("Alpha"),
                                   "section": .string("shown"), "group": .null, "image": .string("/tmp/a.png")]))
        #expect(all[2] == .object(["id": .string("system:wifi"), "app": .string("com.apple.menuextra"), "name": .string("Wi-Fi"),
                                   "section": .null, "group": .string("Network"), "image": .null]))
        let named: [(IconListFilter, [String])] = [(.shown, ["Alpha"]), (.hidden, ["Gamma"]), (.always, ["Beta"]), (.grouped, ["Wi-Fi"])]
        for (filter, names) in named {
            guard case .array(let kept) = CommandAnswers.iconList(rows, filter: filter) else {
                Issue.record("expected an array")
                return
            }
            let found = kept.compactMap { value -> String? in
                if case .object(let object) = value, case .string(let name)? = object["name"] { name } else { nil }
            }
            #expect(found == names, "\(filter)")
        }
        // A group with no title is still a group.
        let untitled = [IconListRow(id: "x", app: "x", name: "X", section: nil, group: "", image: nil)]
        #expect(CommandAnswers.iconList(untitled, filter: .grouped) != .array([]))
    }
}
