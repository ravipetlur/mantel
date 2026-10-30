import Foundation
import MKCore
import Testing

@Suite("Bar appearance and click kinds", .timeLimit(.minutes(1)))
struct BarAppearanceTests {
    @Test func dictionaryEncodesAsObject() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode([BarAppearance.light: 1, BarAppearance.dark: 2])
        #expect(String(decoding: data, as: UTF8.self) == #"{"dark":2,"light":1}"#, "an object with a key for each, not a list")
        let back = try JSONDecoder().decode([BarAppearance: Int].self, from: data)
        #expect(back == [.light: 1, .dark: 2])
    }

    @Test func anUnknownKeyIsNotAnAppearance() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([BarAppearance: Int].self, from: Data(#"{"sepia":1}"#.utf8))
        }
    }

    @Test func clickKindsAreTitledForThePerson() {
        #expect(ClickKind.allCases.map(\.title) == ["Click", "Right-click", "Option-click"])
        #expect(ClickKind.allCases.map(\.rawValue) == ["left", "right", "option"])
    }
}
