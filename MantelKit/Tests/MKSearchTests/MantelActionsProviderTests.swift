import Testing

@testable import MKSearch

@Suite("Mantel actions provider", .timeLimit(.minutes(1)))
struct MantelActionsProviderTests {
    private func offered(focusModeOn: Bool, revealed: Bool) async -> [SearchCandidate] {
        await MantelActionsProvider { MantelActionState(focusModeOn: focusModeOn, revealed: revealed) }.candidates()
    }

    private func action(of candidate: SearchCandidate) -> CommandBarActionID? {
        if case .action(let action) = candidate.kind { return action }
        return nil
    }

    private func actions(_ candidates: [SearchCandidate]) -> [CommandBarActionID] {
        candidates.compactMap(action(of:))
    }

    @Test func titlesAreThePeoplesWords() {
        #expect(CommandBarActionID.allCases.map(\.title) == [
            "Show hidden icons", "Show all icons", "Hide icons again", "Turn Focus Mode on", "Turn Focus Mode off", "Open the second bar",
            "Refresh Menu Bar", "Recapture icons", "Open Settings", "Open Layout settings", "Open Hotkeys settings",
        ])
        #expect(CommandBarActionID.allCases.map(\.rawValue) == [
            "showHidden", "showAll", "hideAgain", "focusModeOn", "focusModeOff", "openSecondBar", "refreshMenuBar", "recaptureIcons",
            "openSettings", "openLayout", "openHotkeys",
        ])
    }

    @Test func onlyApplicableFocusAction() async {
        let off = await offered(focusModeOn: false, revealed: false)
        #expect(actions(off).contains(.focusModeOn))
        #expect(!actions(off).contains(.focusModeOff))

        let on = await offered(focusModeOn: true, revealed: false)
        #expect(actions(on).contains(.focusModeOff))
        #expect(!actions(on).contains(.focusModeOn))

        // Exactly one of the two, whatever else is going on.
        for revealed in [false, true] {
            for focus in [false, true] {
                let candidates = await offered(focusModeOn: focus, revealed: revealed)
                #expect(actions(candidates).filter { $0 == .focusModeOn || $0 == .focusModeOff }.count == 1)
            }
        }
    }

    @Test func hideAgainOnlyWhileRevealed() async {
        #expect(!actions(await offered(focusModeOn: false, revealed: false)).contains(.hideAgain))
        #expect(actions(await offered(focusModeOn: false, revealed: true)).contains(.hideAgain))
        #expect(actions(await offered(focusModeOn: true, revealed: true)).contains(.hideAgain))

        // Everything else is always offered, in the order the actions are declared.
        let always: [CommandBarActionID] = [.showHidden, .showAll, .openSecondBar, .refreshMenuBar, .recaptureIcons, .openSettings,
                                            .openLayout, .openHotkeys]
        let idle = actions(await offered(focusModeOn: false, revealed: false))
        #expect(idle == [.showHidden, .showAll, .focusModeOn] + always.dropFirst(2))
        #expect(always.allSatisfy(idle.contains))
    }

    @Test func candidatesAreActionsBelowIcons() async throws {
        let candidates = await offered(focusModeOn: false, revealed: true)
        for candidate in candidates {
            guard case .action(let action) = candidate.kind else {
                Issue.record("\(candidate.id) isn't an action")
                continue
            }
            #expect(candidate.id == "action:" + action.rawValue)
            #expect(candidate.title == action.title)
            #expect(candidate.boost == -20)
            #expect(candidate.subtitle == nil)
            #expect(!candidate.suggested, "actions aren't listed before anything is typed")
        }
        #expect(Set(candidates.map(\.id)).count == candidates.count)
    }

    @Test func actionsAreFoundByTheirKeywords() async {
        let candidates = await offered(focusModeOn: false, revealed: true)
        func found(by word: String) -> Set<CommandBarActionID> {
            Set(actions(candidates.filter { $0.terms.contains(word) }))
        }
        #expect(found(by: "reveal") == [.showHidden, .showAll])
        #expect(found(by: "hidden").isSuperset(of: [.showHidden, .showAll]))
        #expect(found(by: "focus") == [.focusModeOn])
        #expect(found(by: "bar") == [.openSecondBar])
        #expect(found(by: "settings") == [.openSettings, .openLayout, .openHotkeys])
        #expect(found(by: "images") == [.recaptureIcons])
        #expect(found(by: "capture") == [.recaptureIcons])
        #expect(found(by: "refresh") == [.refreshMenuBar])
    }

    @Test func providerIsNamed() {
        #expect(MantelActionsProvider { MantelActionState(focusModeOn: false, revealed: false) }.name == "Mantel")
        #expect(IconsProvider { [] }.name == "Icons")
    }
}
