import Foundation
import MKTestSupport
import Synchronization
import Testing

@testable import MKCore

@Suite("Panel style", .timeLimit(.minutes(1)))
struct PanelStyleTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private let tint = RGBAColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.5)
    private let other = RGBAColor(red: 1, green: 0, blue: 0.125, alpha: 1)

    @Test func defaultsMatch() throws {
        let style = PanelStyle()
        #expect(style.background == .matchMenuBar)
        #expect(style.appearance == .matchMenuBar)
        #expect(style.border == nil, "nil is the separator border every floating panel has")
        #expect(style.shadow)

        // A file with nothing in it, or with one key, is the defaults with that key.
        #expect(try decode(PanelStyle.self, "{}") == style)
        #expect(try decode(PanelStyle.self, #"{"shadow":false}"#)
            == PanelStyle(background: .matchMenuBar, appearance: .matchMenuBar, border: nil, shadow: false))
        #expect(try decode(PanelStyle.self, #"{"appearance":"dark"}"#)
            == PanelStyle(background: .matchMenuBar, appearance: .dark, border: nil, shadow: true))

        // The parts of a background and of a border that a file leaves out take theirs.
        #expect(try decode(PanelBackground.self, "{}") == .matchMenuBar)
        #expect(try decode(PanelBackground.self, #"{"kind":"material"}"#) == .material(.regular))
        #expect(try decode(PanelBackground.self, #"{"kind":"glass"}"#) == .glass(tint: nil))
        #expect(try decode(PanelBackground.self, #"{"kind":"solid"}"#) == .solid(RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)))
        #expect(try decode(PanelBackground.self, #"{"kind":"gradient"}"#)
            == .gradient(from: RGBAColor(red: 0, green: 0, blue: 0), to: RGBAColor(red: 1, green: 1, blue: 1), angle: 0))
        #expect(try decode(PanelBorder.self, "{}").width == 1)
        #expect(try decode(RGBAColor.self, "{}") == RGBAColor(red: 0, green: 0, blue: 0, alpha: 1))

        // The values a file names: five thicknesses, three appearances.
        #expect(MaterialThickness.allCases.map(\.rawValue) == ["ultraThin", "thin", "regular", "thick", "ultraThick"])
        #expect(PanelAppearance.allCases.map(\.rawValue) == ["matchMenuBar", "light", "dark"])
    }

    @Test func colourClampsOnDecode() throws {
        let wild = try decode(RGBAColor.self, #"{"red":2,"green":-1,"blue":0.5,"alpha":7}"#)
        #expect(wild == RGBAColor(red: 1, green: 0, blue: 0.5, alpha: 1))
        let low = try decode(RGBAColor.self, #"{"red":-0.5,"green":0.25,"blue":-3,"alpha":-1}"#)
        #expect(low == RGBAColor(red: 0, green: 0.25, blue: 0, alpha: 0))
        // Inside 0 to 1 it is left as it is, and a part that is missing is black and opaque.
        #expect(try decode(RGBAColor.self, #"{"red":0.3,"green":0.6,"blue":0.9,"alpha":0.1}"#) == RGBAColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 0.1))
        #expect(try decode(RGBAColor.self, #"{"green":1}"#) == RGBAColor(red: 0, green: 1, blue: 0, alpha: 1))

        // Wherever a colour is in a style, it is brought into range.
        let json = #"{"background":{"kind":"gradient","from":{"red":9,"green":0,"blue":0},"to":{"red":0,"green":0,"blue":-9,"alpha":3},"angle":10},"#
            + #""border":{"color":{"red":5,"green":5,"blue":5,"alpha":5},"width":2}}"#
        let style = try decode(PanelStyle.self, json)
        #expect(style.background == .gradient(from: RGBAColor(red: 1, green: 0, blue: 0), to: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1), angle: 10))
        #expect(style.border == PanelBorder(color: RGBAColor(red: 1, green: 1, blue: 1, alpha: 1), width: 2))
        #expect(try decode(PanelBackground.self, #"{"kind":"solid","color":{"red":2,"green":2,"blue":2}}"#) == .solid(RGBAColor(red: 1, green: 1, blue: 1)))
        #expect(try decode(PanelBackground.self, #"{"kind":"glass","tint":{"red":-1,"green":2,"blue":0,"alpha":2}}"#)
            == .glass(tint: RGBAColor(red: 0, green: 1, blue: 0, alpha: 1)))
    }

    @Test func gradientAngleWraps() throws {
        func angle(_ text: String) throws -> Int? {
            if case .gradient(_, _, let angle) = try decode(PanelBackground.self, #"{"kind":"gradient","angle":\#(text)}"#) { return angle }
            return nil
        }
        // It is a direction: 0 to 359, and one outside them is the same direction inside.
        #expect(try angle("0") == 0)
        #expect(try angle("90") == 90)
        #expect(try angle("359") == 359)
        #expect(try angle("360") == 0)
        #expect(try angle("450") == 90)
        #expect(try angle("-1") == 359)
        #expect(try angle("-90") == 270)
        #expect(try angle("-720") == 0)
        #expect(PanelBackground.wrapped(angle: Int.min) >= 0 && PanelBackground.wrapped(angle: Int.min) < 360)
        #expect(PanelBackground.wrapped(angle: Int.max) >= 0 && PanelBackground.wrapped(angle: Int.max) < 360)

        // A border's width is the other number that is kept in range: 1 to 4.
        #expect(PanelBorder.widthRange == 1...4)
        #expect(try decode(PanelBorder.self, #"{"width":0}"#).width == 1)
        #expect(try decode(PanelBorder.self, #"{"width":-3}"#).width == 1)
        #expect(try decode(PanelBorder.self, #"{"width":3}"#).width == 3)
        #expect(try decode(PanelBorder.self, #"{"width":9}"#).width == 4)
    }

    @Test func roundTrip() throws {
        let backgrounds: [PanelBackground] = [
            .matchMenuBar, .glass(tint: nil), .glass(tint: tint), .solid(other),
            .gradient(from: tint, to: other, angle: 0), .gradient(from: other, to: tint, angle: 359),
        ] + MaterialThickness.allCases.map(PanelBackground.material)
        for background in backgrounds {
            let style = PanelStyle(background: background, appearance: .light, border: PanelBorder(color: tint, width: 4), shadow: false)
            let back = try JSONDecoder().decode(PanelStyle.self, from: JSONEncoder().encode(style))
            #expect(back == style, "\(background)")
            let alone = try JSONDecoder().decode(PanelBackground.self, from: JSONEncoder().encode(background))
            #expect(alone == background, "\(background)")
        }
        for appearance in PanelAppearance.allCases {
            let style = PanelStyle(background: .matchMenuBar, appearance: appearance, border: nil, shadow: true)
            #expect(try JSONDecoder().decode(PanelStyle.self, from: JSONEncoder().encode(style)) == style)
        }

        // A background is an object with its case in `kind`, the part a case needs beside it, and nothing for what is nil.
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(PanelBackground.glass(tint: nil))) as? [String: Any])
        #expect(object["kind"] as? String == "glass")
        #expect(object["tint"] == nil)
        let gradient = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(PanelBackground.gradient(from: tint, to: other, angle: 45))) as? [String: Any])
        #expect(gradient["kind"] as? String == "gradient")
        #expect(gradient["angle"] as? Int == 45)
        #expect((gradient["from"] as? [String: Any])?["alpha"] as? Double == 0.5)
        let material = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(PanelBackground.material(.ultraThick))) as? [String: Any])
        #expect(material["thickness"] as? String == "ultraThick")
    }

    @Test func aBackgroundThisVersionDoesNotKnowIsTheMenuBarsLook() async throws {
        let json = #"{"kind":"holographic","color":{"red":1,"green":0,"blue":0}}"#
        let decoded = Mutex<PanelBackground?>(nil)
        let lines = await LogCapture.lines {
            decoded.withLock { $0 = try? JSONDecoder().decode(PanelBackground.self, from: Data(json.utf8)) }
        }
        #expect(decoded.withLock { $0 } == .matchMenuBar)
        let mentions = lines.filter { $0.contains("a panel background this version doesn't know") }
        #expect(mentions.count == 1, "\(mentions)")
        #expect(!lines.contains { $0.contains("holographic") }, "what the file held is not in the log")
    }

    @Test func theInitializersBringValuesIntoRange() throws {
        // A case can't check what it is given, so the style that holds a background wraps a gradient's angle, and the encoder writes the
        // wrapped one; a border's width is brought into 1 to 4 where it is made.
        func angle(of style: PanelStyle) -> Int? {
            if case .gradient(_, _, let angle) = style.background { return angle }
            return nil
        }
        func style(angle: Int) -> PanelStyle {
            PanelStyle(background: .gradient(from: tint, to: other, angle: angle), appearance: .matchMenuBar, border: nil, shadow: true)
        }
        #expect(angle(of: style(angle: 0)) == 0)
        #expect(angle(of: style(angle: 359)) == 359)
        #expect(angle(of: style(angle: 360)) == 0)
        #expect(angle(of: style(angle: 450)) == 90)
        #expect(angle(of: style(angle: -90)) == 270)
        #expect(style(angle: 450).background == .gradient(from: tint, to: other, angle: 90))
        #expect(PanelStyle(background: .solid(tint), appearance: .dark, border: nil, shadow: false).background == .solid(tint), "other backgrounds are as given")
        let written = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(PanelBackground.gradient(from: tint, to: other, angle: -90))) as? [String: Any])
        #expect(written["angle"] as? Int == 270)

        #expect(PanelBorder(color: tint, width: 0).width == 1)
        #expect(PanelBorder(color: tint, width: -4).width == 1)
        #expect(PanelBorder(color: tint, width: 1).width == 1)
        #expect(PanelBorder(color: tint, width: 4).width == 4)
        #expect(PanelBorder(color: tint, width: 5).width == 4)
        #expect(PanelBorder(color: tint, width: Int.max).width == 4)
        #expect(PanelBorder(color: tint).width == 1)
        #expect(PanelStyle(background: .matchMenuBar, appearance: .matchMenuBar, border: PanelBorder(color: tint, width: 9), shadow: true).border?.width == 4)
    }
}
