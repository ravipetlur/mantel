import MKCore
import Testing

@testable import MKSearch

@Suite("Icon query", .timeLimit(.minutes(1)))
struct IconQueryTests {
    private let weather = SearchFixtures.itemID("com.example.weather")
    private let notes = SearchFixtures.itemID("com.example.notes")
    private let sync = ItemID(bundleID: "com.example.sync", key: .index(1))

    private var entries: [IconSearchEntry] {
        [SearchFixtures.entry(weather, "Weather Station", label: "14 degrees", names: ["forecast"]),
         SearchFixtures.entry(notes, "Notes"),
         SearchFixtures.entry(sync, "Sync Helper", section: .hidden)]
    }

    @Test func exactIDWins() {
        // The ID of one icon is the title of another: the ID is what is meant.
        let tricky = entries + [SearchFixtures.entry(SearchFixtures.itemID("com.example.other"), sync.string)]
        #expect(IconQuery.resolve(sync.string, in: tricky) == .success(sync))
        #expect(IconQuery.resolve("  \(weather.string) ", in: tricky) == .success(weather))
        #expect(IconQuery.resolve("system:wifi", in: tricky + [SearchFixtures.entry(.system("wifi"), "Wi-Fi")]) == .success(.system("wifi")))

        // An ID of an icon that isn't there is words like any other, and matches nothing.
        #expect(IconQuery.resolve("com.example.gone::main", in: entries) == .failure(.noMatch("com.example.gone::main")))
    }

    @Test func uniqueFuzzyResolves() {
        #expect(IconQuery.resolve("weather", in: entries) == .success(weather))
        #expect(IconQuery.resolve("Weath", in: entries) == .success(weather))
        // By initials, by a name the person gave it, and by its label.
        #expect(IconQuery.resolve("ws", in: entries) == .success(weather))
        #expect(IconQuery.resolve("forecast", in: entries) == .success(weather))
        #expect(IconQuery.resolve("degrees", in: entries) == .success(weather))
        #expect(IconQuery.resolve("sync", in: entries) == .success(sync))
        // A second match that is a good deal worse doesn't make it ambiguous: "notes" is exact (1000), and "Weather Station"'s only
        // other match is far below.
        #expect(IconQuery.resolve("NOTES", in: entries) == .success(notes))
        // Accents and spacing don't matter.
        #expect(IconQuery.resolve("  Wéather   Station ", in: entries) == .success(weather))
    }

    @Test func closeSecondIsAmbiguous() {
        let close = [SearchFixtures.entry(SearchFixtures.itemID("com.example.one"), "Mailer One"),
                     SearchFixtures.entry(SearchFixtures.itemID("com.example.two"), "Mailer Two"),
                     SearchFixtures.entry(SearchFixtures.itemID("com.example.three"), "Compass")]
        // Both start with "mailer": 896 each. The titles are those of the closest, in order.
        #expect(IconQuery.resolve("mailer", in: close) == .failure(.ambiguous(["Mailer One", "Mailer Two"])))
        // One of them is told apart by what follows.
        #expect(IconQuery.resolve("mailer o", in: close) == .success(SearchFixtures.itemID("com.example.one")))

        // The second best is below nine tenths of the best (897 against 1000): the best is the icon.
        let apart = [SearchFixtures.entry(SearchFixtures.itemID("com.example.exact"), "Mail"),
                     SearchFixtures.entry(SearchFixtures.itemID("com.example.longer"), "Mailbox")]
        #expect(IconQuery.resolve("mail", in: apart) == .success(SearchFixtures.itemID("com.example.exact")))

        // Initials (700) and a word's start (650) are too close to choose between, and the better one is named first.
        let tight = [SearchFixtures.entry(SearchFixtures.itemID("com.example.gc"), "Green Compass"),
                     SearchFixtures.entry(SearchFixtures.itemID("com.example.big"), "Big Gc Tool")]
        #expect(IconQuery.resolve("gc", in: tight) == .failure(.ambiguous(["Green Compass", "Big Gc Tool"])))
    }

    @Test func atMostFiveTitlesAreListed() {
        let many = (1...8).map { SearchFixtures.entry(SearchFixtures.itemID("com.example.mailer\($0)"), "Mailer \($0)") }
        #expect(IconQuery.resolve("mailer", in: many) == .failure(.ambiguous((1...5).map { "Mailer \($0)" })))
    }

    @Test func noMatchMessage() {
        let result = IconQuery.resolve("zzz", in: entries)
        #expect(result == .failure(.noMatch("zzz")))
        guard case .failure(let error) = result else {
            Issue.record("\(result) isn't a failure")
            return
        }
        let message = "Nothing in the menu bar matches “zzz”. Run “mantel icons” to see them."
        #expect(error.errorDescription == message)
        #expect(error.localizedDescription == message)
        #expect(error.message(for: "zzz") == message)

        // Nothing typed is nothing found, and so is a match that is too weak to count: a and b with 150 characters between.
        #expect(IconQuery.resolve("", in: entries) == .failure(.noMatch("")))
        #expect(IconQuery.resolve("   ", in: entries) == .failure(.noMatch("")))
        let far = [SearchFixtures.entry(SearchFixtures.itemID("com.example.far"), "a" + String(repeating: "x", count: 150) + "b")]
        #expect(IconQuery.resolve("ab", in: far) == .failure(.noMatch("ab")))
        #expect(IconQuery.resolve("zzz", in: []) == .failure(.noMatch("zzz")))
    }

    @Test func ambiguousMessage() {
        let error = IconQueryError.ambiguous(["Mailer One", "Mailer Two"])
        #expect(error.message(for: "mailer") == "“mailer” matches several icons: Mailer One, Mailer Two. Use one of their IDs from “mantel icons”.")
        // On its own the error doesn't know what was typed.
        #expect(error.errorDescription == "Several icons match: Mailer One, Mailer Two. Use one of their IDs from “mantel icons”.")
    }
}
