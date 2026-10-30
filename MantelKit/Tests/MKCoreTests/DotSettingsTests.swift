import Foundation
import MKTestSupport
import Synchronization
import Testing

@testable import MKCore

@Suite("Dot settings", .timeLimit(.minutes(1)))
struct DotSettingsTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private let styles: [DotGlyphStyle] = [
        .dots,
        .chevrons,
        .symbol(hidden: "circle", always: "circle.fill"),
        .image(hiddenLight: "one.png", hiddenDark: nil, alwaysLight: "two.png", alwaysDark: nil),
        .image(hiddenLight: "one.png", hiddenDark: "one-dark.png", alwaysLight: "two.png", alwaysDark: "two-dark.png"),
        .image(hiddenLight: "one.png", hiddenDark: "one-dark.png", alwaysLight: "two.png", alwaysDark: nil),
    ]

    @Test func defaults() throws {
        let settings = DotSettings()
        #expect(settings.style == .dots)
        #expect(settings.alwaysDot == .whenNeeded)
        #expect(!settings.hideBothDots)
        #expect(!settings.showsDivider)

        // A file with nothing in it, or with some of the keys, is the defaults with those.
        #expect(try decode(DotSettings.self, "{}") == settings)
        #expect(try decode(DotSettings.self, #"{"hideBothDots":true}"#)
            == DotSettings(style: .dots, alwaysDot: .whenNeeded, hideBothDots: true, showsDivider: false))
        #expect(try decode(DotSettings.self, #"{"alwaysDot":"always","showsDivider":true}"#)
            == DotSettings(style: .dots, alwaysDot: .always, hideBothDots: false, showsDivider: true))
        // A style with no kind is the dots too.
        #expect(try decode(DotGlyphStyle.self, "{}") == .dots)
        #expect(AlwaysDotVisibility.allCases.map(\.rawValue) == ["whenNeeded", "always"])
    }

    @Test func unknownStyleDecodesAsDots() async throws {
        // A kind a later version wrote, and a symbol or an image with a name left out, are read as the dots, and each says so in the log
        // without saying what the file held.
        let unknown = #"{"style":{"kind":"sparkle","hidden":"star","always":"star.fill"},"hideBothDots":true}"#
        let noSymbol = #"{"style":{"kind":"symbol","hidden":"circle"}}"#
        let noPicture = #"{"style":{"kind":"image","hiddenLight":"one.png"}}"#
        let decoded = Mutex<[DotSettings]>([])
        let lines = await LogCapture.lines {
            for json in [unknown, noSymbol, noPicture] {
                if let settings = try? JSONDecoder().decode(DotSettings.self, from: Data(json.utf8)) {
                    decoded.withLock { $0.append(settings) }
                }
            }
        }
        let settings = decoded.withLock { $0 }
        #expect(settings.count == 3)
        #expect(settings.allSatisfy { $0.style == .dots })
        // The rest of the settings is read as it was.
        #expect(settings.first?.hideBothDots == true)

        let mentions = lines.filter { $0.contains("[settings]") && $0.contains("dot style") }
        #expect(mentions.count == 3, "\(mentions)")
        #expect(mentions.contains { $0.contains("a dot style this version doesn't know was read as dots") })
        #expect(!lines.contains { $0.contains("sparkle") || $0.contains("one.png") }, "what the file held is not in the log")
    }

    @Test func roundTrip() throws {
        for style in styles {
            #expect(try JSONDecoder().decode(DotGlyphStyle.self, from: JSONEncoder().encode(style)) == style, "\(style)")
            let settings = DotSettings(style: style, alwaysDot: .always, hideBothDots: true, showsDivider: true)
            #expect(try JSONDecoder().decode(DotSettings.self, from: JSONEncoder().encode(settings)) == settings, "\(style)")
        }
        #expect(try JSONDecoder().decode(DotSettings.self, from: JSONEncoder().encode(DotSettings())) == DotSettings())

        // A style is an object with its case in `kind`; a picture that is left out isn't written.
        let symbol = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(styles[2])) as? [String: Any])
        #expect(symbol["kind"] as? String == "symbol")
        #expect(symbol["hidden"] as? String == "circle")
        #expect(symbol["always"] as? String == "circle.fill")
        let image = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(styles[3])) as? [String: Any])
        #expect(image["kind"] as? String == "image")
        #expect(image["hiddenLight"] as? String == "one.png")
        #expect(image["hiddenDark"] == nil)
        #expect(image["alwaysDark"] == nil)
    }
}
