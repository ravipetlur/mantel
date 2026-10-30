import MKCore
import Testing

@testable import MKLayout

/// The line the log has when the sections are saved: what changed and who changed it, in bundle IDs, section names and counts.
@Suite("Section change log", .timeLimit(.minutes(2)))
struct SectionChangeLogTests {
    private let a = "com.example.a"
    private let b = "com.example.b"

    private func model(shown: [String] = [], hidden: [String] = []) -> SectionModel {
        var model = SectionModel()
        for app in shown { model.move(app: app, to: .shown) }
        for app in hidden { model.move(app: app, to: .hidden) }
        return model
    }

    @Test func aSaveThatChangedNothingHasNoLine() {
        let start = model(shown: [a], hidden: [b])
        var log = SectionChangeLog(from: start)
        #expect(log.line == nil)
        log.took(start, by: .person)
        #expect(log.line == nil, "a step that left the sections as they were says nothing")
    }
}
