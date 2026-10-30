import MKCore
import Testing

@testable import MKSearch

@Suite("Command bar search", .timeLimit(.minutes(1)))
struct CommandBarSearchTests {
    private func opened(_ candidates: [SearchCandidate], recents: [String] = []) async -> CommandBarSearch {
        let search = CommandBarSearch(providers: [StubProvider(offering: candidates)], recents: recents)
        await search.open()
        return search
    }

    @Test func providersAskedOnlyAtOpen() async {
        let first = StubProvider("First", offering: [SearchFixtures.iconCandidate("Weather Station")])
        let second = StubProvider("Second", offering: [SearchFixtures.iconCandidate("Notes")])
        let search = CommandBarSearch(providers: [first, second], recents: [])
        #expect(first.timesAsked == 0)
        #expect(await search.results(for: "weather").isEmpty, "nothing is offered before the bar opens")

        await search.open()
        #expect(first.timesAsked == 1)
        #expect(second.timesAsked == 1)

        // Typing, choosing and typing again filter what was offered, and ask nobody.
        for query in ["w", "we", "wea", "notes", "", "zzz"] {
            _ = await search.results(for: query)
        }
        _ = await search.picked("icon:com.example.notes")
        _ = await search.results(for: "not")
        #expect(first.timesAsked == 1)
        #expect(second.timesAsked == 1)

        await search.open()
        #expect(first.timesAsked == 2)
        #expect(second.timesAsked == 2)
    }

    @Test func offeredCandidatesAreListedInProviderOrderWithoutRepeats() async {
        let shared = SearchFixtures.iconCandidate("Weather Station", suggested: true)
        let other = SearchFixtures.iconCandidate("Notes", suggested: true)
        let search = CommandBarSearch(providers: [StubProvider("A", offering: [shared]),
                                                  StubProvider("B", offering: [other, SearchFixtures.iconCandidate("Weather Station", terms: ["x"], suggested: true)])],
                                      recents: [])
        await search.open()
        // The second provider's candidate with an ID the first one had is left out.
        #expect(await search.results(for: "").map(\.candidate) == [shared, other])
    }

    @Test func customNameFindsIcon() async throws {
        let search = await opened([SearchFixtures.iconCandidate("Weather Station", terms: ["forecast", "rain"]),
                                   SearchFixtures.iconCandidate("Notes")])
        let results = await search.results(for: "forecast")
        #expect(results.map(\.candidate.title) == ["Weather Station"])
        let found = try #require(results.first)
        #expect(found.score == 1000, "a custom name counts in full")
        #expect(found.titleOffsets.isEmpty, "the title isn't what matched")

        // And the name is found as the title is: by its start, and by its initials.
        #expect(await search.results(for: "fore").map(\.candidate.title) == ["Weather Station"])
        #expect(await search.results(for: "RAIN").map(\.candidate.title) == ["Weather Station"])
    }

    @Test func labelFindsIconBelowName() async throws {
        let labelled = SearchFixtures.iconCandidate("Compass", weakTerms: ["Radar"])
        let named = SearchFixtures.iconCandidate("Radar Station")
        let search = await opened([labelled, named])
        let results = await search.results(for: "radar")
        // The label is found, but at four fifths of what the same match on a name is, and below a name that starts with the query.
        #expect(results.map(\.candidate.title) == ["Radar Station", "Compass"])
        #expect(results[0].score == 892)
        #expect(results[1].score == 800)

        // A name found in full outranks the label of another icon that matches as well.
        let custom = SearchFixtures.iconCandidate("Dial", terms: ["radar"])
        let both = await opened([labelled, custom])
        #expect(await both.results(for: "radar").map(\.candidate.title) == ["Dial", "Compass"])
    }

    @Test func subtitleCountsForLess() async throws {
        let search = await opened([SearchFixtures.iconCandidate("Notes", subtitle: "Hidden"),
                                   SearchFixtures.iconCandidate("Hidden Notes")])
        let results = await search.results(for: "hidden")
        #expect(results.map(\.candidate.title) == ["Hidden Notes", "Notes"])
        // The subtitle's exact match is 1000 at 0.6.
        #expect(results[1].score == 600)
    }

    @Test func titleOffsetsAreTheTitlesMatch() async throws {
        let search = await opened([SearchFixtures.iconCandidate("Green Compass", terms: ["north"])])
        #expect(try #require(await search.results(for: "gc").first).titleOffsets == [0, 6])
        #expect(try #require(await search.results(for: "comp").first).titleOffsets == [6, 7, 8, 9])
        // What another name matched says nothing of the title's characters.
        #expect(try #require(await search.results(for: "north").first).titleOffsets.isEmpty)
    }

    @Test func recentsBoost() async throws {
        let box = SearchFixtures.iconCandidate("Mailbox")
        let merge = SearchFixtures.iconCandidate("Mail Merge")
        let flow = SearchFixtures.iconCandidate("Mail Flow")
        // Without any recent pick, the closer prefix is first: 900 less the characters over, 3, 5 and 6.
        let plain = await opened([merge, box, flow])
        #expect(await plain.results(for: "mail").map(\.score) == [897, 895, 894])
        #expect(await plain.results(for: "mail").map(\.candidate.title) == ["Mailbox", "Mail Flow", "Mail Merge"])

        // A recent pick gains 60 if it's the newest, and 3 less for each place after.
        let newest = await opened([merge, box, flow], recents: [merge.id])
        #expect(await newest.results(for: "mail").map(\.candidate.title) == ["Mail Merge", "Mailbox", "Mail Flow"])
        #expect(await newest.results(for: "mail").map(\.score) == [954, 897, 895])

        let older = await opened([merge, box, flow], recents: ["icon:com.example.gone", merge.id])
        #expect(await older.results(for: "mail").first?.score == 894 + 57)

        // Choosing a result makes it the newest, and the search knows at once.
        let search = await opened([merge, box, flow])
        #expect(await search.picked(flow.id) == [flow.id])
        #expect(await search.results(for: "mail").first?.candidate.title == "Mail Flow")
        #expect(await search.picked(merge.id) == [merge.id, flow.id])
        #expect(await search.results(for: "mail").map(\.candidate.title) == ["Mail Merge", "Mail Flow", "Mailbox"])
        // Picking one again moves it, and doesn't add it twice.
        #expect(await search.picked(flow.id) == [flow.id, merge.id])
    }

    @Test func recentPicksAreAtMostTwenty() async {
        let search = CommandBarSearch(providers: [], recents: (0..<30).map { "icon:com.example.app\($0)" })
        var recents: [String] = []
        for number in 100..<125 {
            recents = await search.picked("icon:com.example.app\(number)")
        }
        #expect(recents.count == IconPreferences.maxRecentPicks)
        #expect(recents.first == "icon:com.example.app124")
        #expect(recents.last == "icon:com.example.app105")
    }

    @Test func emptyQueryListsRecentsThenHidden() async {
        let hiddenOne = SearchFixtures.iconCandidate("Hidden One", subtitle: "Hidden", suggested: true)
        let hiddenTwo = SearchFixtures.iconCandidate("Hidden Two", subtitle: "Hidden", suggested: true)
        let hiddenThree = SearchFixtures.iconCandidate("Hidden Three", subtitle: "Hidden", suggested: true)
        let shownOne = SearchFixtures.iconCandidate("Shown One", subtitle: "Shown")
        let shownTwo = SearchFixtures.iconCandidate("Shown Two", subtitle: "Shown")
        let offered = [shownOne, hiddenOne, shownTwo, hiddenTwo, hiddenThree]

        // Nothing picked yet: the hidden icons, in the order they were offered.
        let fresh = await opened(offered)
        #expect(await fresh.results(for: "").map(\.candidate.title) == ["Hidden One", "Hidden Two", "Hidden Three"])
        #expect(await fresh.results(for: "   ").map(\.candidate.title) == ["Hidden One", "Hidden Two", "Hidden Three"])

        // The recent picks first, newest first, whichever they are; one that isn't offered now is skipped; and a hidden icon that is a
        // recent pick is listed once.
        let search = await opened(offered, recents: [shownTwo.id, "icon:com.example.gone", hiddenTwo.id])
        #expect(await search.results(for: "").map(\.candidate.title) == ["Shown Two", "Hidden Two", "Hidden One", "Hidden Three"])
        #expect(await search.results(for: "").allSatisfy { $0.titleOffsets.isEmpty })

        // A list as long as the limit stops there.
        let crowd = (0..<20).map { SearchFixtures.iconCandidate("Crowd \($0)", suggested: true) }
        let many = await opened(crowd, recents: [shownOne.id])
        #expect(await many.results(for: "").count == CommandBarSearch.limit)
    }

    @Test func actionsBelowEqualIcons() async throws {
        let icon = SearchFixtures.iconCandidate("Open Settings", subtitle: "Shown")
        let actions = MantelActionsProvider { MantelActionState(focusModeOn: false, revealed: false) }
        let search = CommandBarSearch(providers: [actions, StubProvider(offering: [icon])], recents: [])
        await search.open()

        // Both match "open settings" exactly; the action is held 20 below.
        let results = await search.results(for: "open settings")
        #expect(results.prefix(2).map(\.candidate.title) == ["Open Settings", "Open Settings"])
        #expect(results[0].candidate.kind == icon.kind)
        #expect(results[0].score == 1000)
        #expect(results[1].candidate.kind == .action(.openSettings))
        #expect(results[1].score == 980)

        // But an action that matches better is above an icon that matches worse.
        let better = await search.results(for: "second bar")
        #expect(better.first?.candidate.kind == .action(.openSecondBar))
    }

    @Test func limitTwelve() async {
        #expect(CommandBarSearch.limit == 12)
        let titles = (0..<30).map { "Tool \($0 < 10 ? "0" : "")\($0)" }
        let search = await opened(titles.reversed().map { SearchFixtures.iconCandidate($0) })
        let results = await search.results(for: "tool")
        // The same score for each, so the first twelve by title.
        #expect(results.map(\.candidate.title) == Array(titles.prefix(12)))
    }

    @Test func tiesByTitle() async {
        // Each is a word that starts with "tool": the same score.
        let search = await opened([SearchFixtures.iconCandidate("Zeta Tool"), SearchFixtures.iconCandidate("beta Tool"),
                                   SearchFixtures.iconCandidate("Alpha Tool"), SearchFixtures.iconCandidate("Café Tool")])
        let results = await search.results(for: "tool")
        #expect(Set(results.map(\.score)).count == 1)
        // By the title as it is compared: without case or accents.
        #expect(results.map(\.candidate.title) == ["Alpha Tool", "beta Tool", "Café Tool", "Zeta Tool"])

        // The same title: by ID.
        let twins = await opened([SearchFixtures.iconCandidate("Tool Box", bundleID: "com.example.b"),
                                  SearchFixtures.iconCandidate("Tool Box", bundleID: "com.example.a")])
        #expect(await twins.results(for: "tool").map(\.id) == ["icon:com.example.a::main", "icon:com.example.b::main"])
    }

    @Test func fiveHundredCandidatesAreFast() async throws {
        let names = ["Green", "Compass", "Weather", "Station", "Notes", "Radar", "Capture", "Sync", "Mail", "Timer"]
        let candidates = (0..<500).map { number in
            SearchFixtures.iconCandidate("\(names[number % 10]) \(names[(number / 10) % 10]) \(number)", bundleID: "com.example.app\(number)",
                                         terms: ["name \(number)", "other \(names[number % 7])"],
                                         // A label that every fifth candidate has, as long as a real one can be, that the query below is a
                                         // subsequence of and no more.
                                         weakTerms: number % 5 == 0 ? ["the quick brown fox jumps over the lazy dog \(number)"] : [],
                                         subtitle: number % 3 == 0 ? "Hidden" : "Shown")
        }
        let search = await opened(candidates)

        // Ten characters, in order in a hundred of the labels.
        let query = "equickbrwn"
        let found = await search.results(for: query)
        #expect(await search.results(for: query).count == CommandBarSearch.limit)
        #expect(!found.isEmpty)

        let clock = ContinuousClock()
        var fastest = Duration.seconds(10)
        for _ in 0..<5 {
            let took = await clock.measure { _ = await search.results(for: query) }
            fastest = min(fastest, took)
        }
        // Typing must feel instant: a few milliseconds is what it takes. The limit has a hundred times that, because it is wall time: on
        // a loaded machine a search is held up by whatever else is running, and a limit near what it takes fails the test for the load.
        // What it still catches is a search that has become far slower (a pass over the labels for every character, say).
        #expect(fastest < .milliseconds(500), "took \(fastest)")
    }

    @Test func overlappingOpensKeepTheLatestAnswers() async {
        let provider = FirstCallWaitsProvider(first: [SearchFixtures.iconCandidate("Old Name")], later: [SearchFixtures.iconCandidate("New Name")])
        let search = CommandBarSearch(providers: [provider], recents: [])
        let earlier = Task { await search.open() }
        await provider.firstCallStarted()

        // The later opening is answered while the earlier one is still waiting, and the earlier one finishes last.
        await search.open()
        provider.releaseFirstCall()
        await earlier.value

        #expect(await search.results(for: "name").map(\.candidate.title) == ["New Name"])
    }
}
