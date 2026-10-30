import Testing

@testable import MKSearch

@Suite("Icon query words")
struct IconQueryWordsTests {
    @Test func aNoMatchNamesTheQuery() {
        #expect(IconQueryError.noMatch("zzz").answer(for: "zzz") == "Nothing in the menu bar matches “zzz”. Run “mantel icons” to see them.")
    }

    @Test func ambiguousTitlesAreListedAsTheErrorWordsThem() {
        #expect(IconQueryError.ambiguous(["Notes", "Notion"]).answer(for: "not")
                == "“not” matches several icons: Notes, Notion. Use one of their IDs from “mantel icons”.")
    }

    @Test func aTitleThatRepeatsIsSaidOnceWithHowManyIconsCarryIt() {
        // Two icons of one app have the same title.
        #expect(IconQueryError.ambiguous(["Notes", "Notes", "Notion"]).answer(for: "not")
                == "“not” matches several icons: Notes (2 icons), Notion. Use one of their IDs from “mantel icons”.")
        #expect(IconQueryError.ambiguous(["Notes", "Notes"]).answer(for: "notes")
                == "“notes” matches several icons: Notes (2 icons). Use one of their IDs from “mantel icons”.")
    }
}
