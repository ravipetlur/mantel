import MKCommands
import MKCore
import Testing

@Suite("Command answers", .timeLimit(.minutes(2)))
struct CommandAnswersTests {
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

    // MARK: Icons, the bar, the pictures and the order

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
