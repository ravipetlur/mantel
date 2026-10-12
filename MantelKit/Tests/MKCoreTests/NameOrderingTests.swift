import Testing

@testable import MKCore

@Suite("Name ordering", .timeLimit(.minutes(1)))
struct NameOrderingTests {
    private func order(_ names: [String]) -> [String] {
        NameOrdering.sorted(names, name: { $0 }, tiebreak: { $0 })
    }

    @Test func lettersAreOrderedWithoutRegardToCase() {
        #expect(order(["zoom", "Alpha", "beta", "Charlie"]) == ["Alpha", "beta", "Charlie", "zoom"])
    }

    @Test func numbersAreOrderedByTheirValue() {
        #expect(order(["App 10", "App 2", "App 1"]) == ["App 1", "App 2", "App 10"])
    }

    @Test func namesThatAreTheSameKeepTheOrderOfTheirTiebreak() {
        struct Entry: Equatable {
            let name: String
            let id: String
        }
        let entries = [Entry(name: "Same", id: "b"), Entry(name: "Same", id: "a"), Entry(name: "Other", id: "z")]
        let sorted = NameOrdering.sorted(entries, name: \.name, tiebreak: \.id)
        #expect(sorted == [Entry(name: "Other", id: "z"), Entry(name: "Same", id: "a"), Entry(name: "Same", id: "b")])
        #expect(NameOrdering.sorted(entries.reversed(), name: \.name, tiebreak: \.id) == sorted)
    }

    @Test func nothingToOrderIsNothing() {
        #expect(order([]).isEmpty)
        #expect(order(["only"]) == ["only"])
    }

    // MARK: Names of apps

    @Test func anAppIsNamedByItsRunningNameFirst() {
        #expect(AppNames.resolve(bundleID: "com.example.app", runningName: "Running", bundleName: "Bundle") == "Running")
    }

    @Test func thenByItsBundleThenByItsBundleID() {
        #expect(AppNames.resolve(bundleID: "com.example.app", runningName: nil, bundleName: "Bundle") == "Bundle")
        #expect(AppNames.resolve(bundleID: "com.example.app", runningName: "  ", bundleName: "Bundle") == "Bundle")
        #expect(AppNames.resolve(bundleID: "com.example.app", runningName: nil, bundleName: nil) == "com.example.app")
        #expect(AppNames.resolve(bundleID: "com.example.app", runningName: "", bundleName: "\n") == "com.example.app")
    }

    @Test func aNameIsTrimmed() {
        #expect(AppNames.resolve(bundleID: "com.example.app", runningName: "  Padded \n", bundleName: nil) == "Padded")
    }
}
