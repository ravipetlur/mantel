import Foundation
import Testing

@testable import MKMenuBar

@Suite("Probe options", .timeLimit(.minutes(1)))
struct ProbeOptionsTests {
    @Test func aNumberIsClampedToTheRange() {
        #expect(ProbeOptions(["hold": "12"]).int("hold", default: 5, range: 1...30) == 12)
        #expect(ProbeOptions(["hold": "0"]).int("hold", default: 5, range: 1...30) == 1)
        #expect(ProbeOptions(["hold": "-4"]).int("hold", default: 5, range: 1...30) == 1)
        #expect(ProbeOptions(["hold": "500"]).int("hold", default: 5, range: 1...30) == 30)
        #expect(ProbeOptions(["delay": "10"]).int("delay", default: 100, range: 20...400) == 20)
        #expect(ProbeOptions(["delay": "9999"]).int("delay", default: 100, range: 20...400) == 400)
    }

    @Test func aMissingOrUnreadableNumberIsTheDefault() {
        #expect(ProbeOptions([:]).int("hold", default: 5, range: 1...30) == 5)
        #expect(ProbeOptions(["hold": "soon"]).int("hold", default: 5, range: 1...30) == 5)
        #expect(ProbeOptions(["hold": ""]).int("hold", default: 5, range: 1...30) == 5)
        #expect(ProbeOptions(["hold": " 7 "]).int("hold", default: 5, range: 1...30) == 7, "spaces around it don't matter")
    }

    @Test func aNumberTooBigForAnIntIsClampedNotACrash() {
        #expect(ProbeOptions(["hold": "99999999999999999999999"]).int("hold", default: 5, range: 1...30) == 5)
    }

    @Test func aListIsSplitOnCommasAndTrimmed() {
        #expect(ProbeOptions(["apps": "com.a, com.b ,,com.c "]).list("apps") == ["com.a", "com.b", "com.c"])
        #expect(ProbeOptions(["apps": "single"]).list("apps") == ["single"])
        #expect(ProbeOptions(["apps": ""]).list("apps") == [])
        #expect(ProbeOptions(["apps": " , ,"]).list("apps") == [])
        #expect(ProbeOptions([:]).list("apps") == [])
    }

    @Test func aStringIsTrimmedAndEmptyIsNone() {
        #expect(ProbeOptions(["app": " com.a "]).string("app") == "com.a")
        #expect(ProbeOptions(["app": "  "]).string("app") == nil)
        #expect(ProbeOptions([:]).string("app") == nil)
    }

    @Test func allowAnyIsOnlyForTrue() {
        #expect(ProbeOptions(["allow-any": "true"]).allowAny)
        #expect(ProbeOptions(["allow-any": "TRUE"]).allowAny)
        #expect(ProbeOptions(["allow-any": "1"]).allowAny)
        #expect(!ProbeOptions(["allow-any": "false"]).allowAny)
        #expect(!ProbeOptions(["allow-any": "no"]).allowAny)
        #expect(!ProbeOptions([:]).allowAny)
    }

    @Test func numbersAreReadAsARangeOrAList() {
        #expect(ProbeOptions(["system-items": "0-3"]).numbers("system-items") == [0, 1, 2, 3])
        #expect(ProbeOptions(["system-items": "2,5, 6"]).numbers("system-items") == [2, 5, 6])
        #expect(ProbeOptions(["system-items": "1-2,8"]).numbers("system-items") == [1, 2, 8])
        #expect(ProbeOptions(["system-items": "3-1"]).numbers("system-items") == [1, 2, 3], "a backwards range is the same range")
        #expect(ProbeOptions([:]).numbers("system-items") == nil)
        #expect(ProbeOptions(["system-items": "a-b"]).numbers("system-items") == nil, "unreadable is none, so the default is used")
    }

    @Test func aHugeRangeIsCutShort() throws {
        let numbers = try #require(ProbeOptions(["system-items": "0-999999999"]).numbers("system-items"))
        #expect(numbers.count == ProbeOptions.maximumNumbers)
        #expect(numbers.first == 0)
    }
}

@Suite("Probe safety", .timeLimit(.minutes(1)))
struct ProbeSafetyTests {
    @Test func theFixtureSuffixIsPermitted() {
        #expect(ProbeSafety.fixtureBundleIDSuffix == ".testitem")
        let result = ProbeSafety.permitted(["com.example.mantel.testitem", "com.sample.mantel.testitem"], options: ProbeOptions([:]))
        #expect(result == .success(["com.example.mantel.testitem", "com.sample.mantel.testitem"]))
    }

    @Test func anotherAppIsRefusedWithTheWordsToUse() {
        let result = ProbeSafety.permitted(["com.example.mantel.testitem", "com.apple.Safari"], options: ProbeOptions([:]))
        #expect(result == .failure(ProbeRefusal(message: "This probe only touches MantelTestItem. Add --allow-any to touch com.apple.Safari.")))
    }

    @Test func theFirstAppThatIsNotTheFixtureIsTheOneNamed() {
        let result = ProbeSafety.permitted(["com.b", "com.a"], options: ProbeOptions([:]))
        #expect(result == .failure(ProbeRefusal(message: "This probe only touches MantelTestItem. Add --allow-any to touch com.b.")))
    }

    @Test func allowAnyPermitsAnyApp() {
        let result = ProbeSafety.permitted(["com.apple.Safari"], options: ProbeOptions(["allow-any": "true"]))
        #expect(result == .success(["com.apple.Safari"]))
    }

    @Test func aBundleIDThatOnlyEndsLikeTheSuffixIsNotTheFixture() {
        // ".testitem" has to be a whole part: "notatestitem" isn't one.
        let result = ProbeSafety.permitted(["com.example.notatestitem"], options: ProbeOptions([:]))
        #expect(result == .failure(ProbeRefusal(message: "This probe only touches MantelTestItem. Add --allow-any to touch com.example.notatestitem.")))
    }

    @Test func everySystemItemOnTheAllowlistHidesNoneAndNeedsNothing() {
        #expect(ProbeSafety.permittedSystemItems(Array(0...255), options: ProbeOptions([:])) == .success(Array(0...255)))
        #expect(ProbeSafety.permittedSystemItems(Array(0...300), options: ProbeOptions([:])) == .success(Array(0...300)))
        let shuffled = Array(0...255).shuffled()
        #expect(ProbeSafety.permittedSystemItems(shuffled, options: ProbeOptions([:])) == .success(shuffled), "in any order")
    }

    @Test func fewerSystemItemsHideSomeAndNeedAllowAny() {
        let refusal = ProbeRefusal(message: "This probe only hides MantelTestItem. Add --allow-any to hide system items.")
        #expect(ProbeSafety.permittedSystemItems([2, 5, 6], options: ProbeOptions([:])) == .failure(refusal))
        #expect(ProbeSafety.permittedSystemItems([], options: ProbeOptions([:])) == .failure(refusal))
        #expect(ProbeSafety.permittedSystemItems(Array(1...255), options: ProbeOptions([:])) == .failure(refusal))
        #expect(ProbeSafety.permittedSystemItems([2, 5, 6], options: ProbeOptions(["allow-any": "true"])) == .success([2, 5, 6]))
    }

    @Test func nothingToTouchIsFine() {
        #expect(ProbeSafety.permitted([], options: ProbeOptions([:])) == .success([]))
    }
}
