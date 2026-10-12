import Foundation
import MKCommands
import Testing

@Suite("Commands and results as JSON")
struct CommandCodableTests {
    static let commands: [MantelCommand] = {
        var all: [MantelCommand] = [.ping, .version, .openSettings(nil), .diagnostics, .refresh, .reset, .engine]
        all += SettingsPage.allCases.map { .openSettings($0) }
        all += ShowTarget.allCases.map { .show($0) }
        all += FocusChange.allCases.map { .focus($0) }
        for name in ProbeName.allCases {
            all.append(.probe(name, options: [:]))
            all.append(.probe(name, options: ["bundle-id": "com.example.item", "allow-any": "true"]))
        }
        return all
    }()

    static let results: [CommandResult] = {
        var all: [CommandResult] = [
            .ok(.null), .ok(.bool(true)), .ok(.bool(false)), .ok(.number(0)), .ok(.number(-12.5)),
            .ok(.string("pong")), .ok(.string("line\nbreak \"quoted\" é")), .ok(.array([])),
            .ok(.array([.number(1), .string("two"), .null, .array([.bool(true)])])),
            .ok(.object([:])),
            .ok(.object(["version": .string("0.1.0"), "nested": .object(["list": .array([.number(3)])])])),
        ]
        for code in [CommandErrorCode.badRequest, .rejected, .unavailable, .failed, .unknownCommand] {
            all.append(.failure(code: code, message: "It didn't work. Try again."))
        }
        return all
    }()

    private func json(_ value: some Encodable) throws -> String {
        let data = try LineCodec.encode(value)
        return String(decoding: data.dropLast(), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    // MARK: Round trips

    @Test(arguments: commands) func everyCommandRoundTrips(command: MantelCommand) throws {
        let data = try LineCodec.encode(command)
        #expect(try JSONDecoder().decode(MantelCommand.self, from: data) == command)
    }

    @Test(arguments: results) func everyResultRoundTrips(result: CommandResult) throws {
        let data = try LineCodec.encode(result)
        #expect(try JSONDecoder().decode(CommandResult.self, from: data) == result)
    }

    @Test func envelopesRoundTrip() throws {
        let request = RequestEnvelope(id: UUID(), command: .probe(.inventory, options: ["a": "b"]))
        #expect(try JSONDecoder().decode(RequestEnvelope.self, from: LineCodec.encode(request)) == request)

        let answered = ReplyEnvelope(id: UUID(), result: .ok(.string("pong")))
        #expect(try JSONDecoder().decode(ReplyEnvelope.self, from: LineCodec.encode(answered)) == answered)

        // A reply that answers no request (a refused client) has no id.
        let unanswered = ReplyEnvelope(id: nil, result: .failure(code: .rejected, message: "No."))
        let data = try LineCodec.encode(unanswered)
        #expect(try JSONDecoder().decode(ReplyEnvelope.self, from: data) == unanswered)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"id\""))
    }

    // MARK: The wire format, which the app and the tool must agree on

    @Test func commandsAreWrittenWithTheirNameAndTheirArguments() throws {
        #expect(try json(MantelCommand.ping) == #"{"command":"ping"}"#)
        #expect(try json(MantelCommand.version) == #"{"command":"version"}"#)
        #expect(try json(MantelCommand.diagnostics) == #"{"command":"diagnostics"}"#)
        #expect(try json(MantelCommand.openSettings(nil)) == #"{"command":"openSettings"}"#)
        #expect(try json(MantelCommand.openSettings(.hotkeys)) == #"{"command":"openSettings","page":"hotkeys"}"#)
        #expect(try json(MantelCommand.probe(.menuBarHeight, options: ["allow-any": "true"]))
                == #"{"command":"probe","name":"menu-bar-height","options":{"allow-any":"true"}}"#)
    }

    @Test func theMenuBarCommandsAreWrittenWithTheirNameAndTheirArguments() throws {
        #expect(try json(MantelCommand.show(.hidden)) == #"{"command":"show","target":"hidden"}"#)
        #expect(try json(MantelCommand.show(.all)) == #"{"command":"show","target":"all"}"#)
        // The case that is `.nothing` in code is the word `none` on the wire and on the command line.
        #expect(try json(MantelCommand.show(.nothing)) == #"{"command":"show","target":"none"}"#)
        // The encoder writes the keys in order, so `change` comes before `command`; a reader takes them in any order.
        #expect(try json(MantelCommand.focus(.on)) == #"{"change":"on","command":"focus"}"#)
        #expect(try json(MantelCommand.focus(.off)) == #"{"change":"off","command":"focus"}"#)
        #expect(try json(MantelCommand.focus(.toggle)) == #"{"change":"toggle","command":"focus"}"#)
        #expect(try json(MantelCommand.refresh) == #"{"command":"refresh"}"#)
        #expect(try json(MantelCommand.reset) == #"{"command":"reset"}"#)
        #expect(try json(MantelCommand.engine) == #"{"command":"engine"}"#)
    }

    @Test func theMenuBarCommandsAreReadFromTheirWire() throws {
        #expect(try decode(MantelCommand.self, from: #"{"command":"show","target":"none"}"#) == .show(.nothing))
        #expect(try decode(MantelCommand.self, from: #"{"change":"toggle","command":"focus"}"#) == .focus(.toggle))
        #expect(try decode(MantelCommand.self, from: #"{"command":"refresh"}"#) == .refresh)
        #expect(try decode(MantelCommand.self, from: #"{"command":"reset"}"#) == .reset)
        #expect(try decode(MantelCommand.self, from: #"{"command":"engine"}"#) == .engine)
    }

    @Test func showAndFocusSpellTheirWordsInLowerCase() {
        #expect(ShowTarget.allCases.map(\.rawValue) == ["hidden", "all", "none"])
        #expect(FocusChange.allCases.map(\.rawValue) == ["on", "off", "toggle"])
    }

    @Test func resultsAreWrittenWithAStatus() throws {
        #expect(try json(CommandResult.ok(.string("pong"))) == #"{"status":"ok","value":"pong"}"#)
        #expect(try json(CommandResult.ok(.null)) == #"{"status":"ok","value":null}"#)
        #expect(try json(CommandResult.failure(code: .unavailable, message: "Not yet."))
                == #"{"code":"unavailable","message":"Not yet.","status":"failure"}"#)
    }

    @Test func aProbeWithoutOptionsIsStillReadable() throws {
        let command = try decode(MantelCommand.self, from: #"{"command":"probe","name":"capture"}"#)
        #expect(command == .probe(.capture, options: [:]))
    }

    @Test func anOkResultWithoutAValueIsNull() throws {
        #expect(try decode(CommandResult.self, from: #"{"status":"ok"}"#) == .ok(.null))
    }

    @Test(arguments: [
        #"{"command":"explode"}"#,
        #"{"command":"openSettings","page":"bogus"}"#,
        #"{"command":"probe","name":"bogus"}"#,
        #"{"command":"probe"}"#,
        #"{"command":"show"}"#,
        #"{"command":"show","target":"some"}"#,
        #"{"command":"show","target":"nothing"}"#,
        #"{"command":"focus"}"#,
        #"{"command":"focus","change":"maybe"}"#,
        #"{"page":"general"}"#,
        #"["ping"]"#,
        #""ping""#,
        "{}",
    ]) func aCommandNobodyKnowsIsRefused(text: String) {
        #expect(throws: DecodingError.self) { try decode(MantelCommand.self, from: text) }
    }

    @Test(arguments: [
        #"{"status":"maybe"}"#,
        #"{"status":"failure","code":"bogus","message":"x"}"#,
        #"{"status":"failure","code":"failed"}"#,
        #"{"value":1}"#,
    ]) func aResultNobodyKnowsIsRefused(text: String) {
        #expect(throws: DecodingError.self) { try decode(CommandResult.self, from: text) }
    }

    // MARK: Probe names

    @Test func probeNamesAreSpelledAsTheCommandLineSpellsThem() {
        let spellings: [ProbeName: String] = [
            .allowlistInfo: "allowlist-info", .allowlistActivate: "allowlist-activate", .inventory: "inventory",
            .approvalsRead: "approvals-read", .approvalsToggle: "approvals-toggle",
            .layoutRead: "layout-read", .layoutMove: "layout-move",
            .capture: "capture", .clickReplay: "click-replay", .overflow: "overflow",
            .screenShare: "screen-share", .menuBarHeight: "menu-bar-height",
            .grantPersistence: "grant-persistence",
            .revealLatency: "reveal-latency", .approvalsDecode: "approvals-decode", .approvalsFlip: "approvals-flip",
            .notchCoordinates: "notch-coordinates",
        ]
        #expect(spellings.count == ProbeName.allCases.count, "every probe has a spelling here")
        for (name, spelling) in spellings {
            #expect(name.rawValue == spelling)
        }
    }

    @Test func newPagesRoundTrip() throws {
        for (page, word) in [(SettingsPage.layout, "layout"), (.advanced, "advanced")] {
            #expect(page.rawValue == word)
            let command = MantelCommand.openSettings(page)
            #expect(try json(command) == "{\"command\":\"openSettings\",\"page\":\"\(word)\"}")
            #expect(try decode(MantelCommand.self, from: "{\"command\":\"openSettings\",\"page\":\"\(word)\"}") == command)
            let data = try JSONEncoder().encode(command)
            #expect(try JSONDecoder().decode(MantelCommand.self, from: data) == command)
        }
    }

    @Test func settingsPagesAreSpelledInLowerCase() {
        #expect(SettingsPage.allCases.map(\.rawValue) == ["general", "layout", "hotkeys", "permissions", "advanced", "diagnostics", "about"])
    }

    // MARK: JSON values

    @Test func jsonValuesReadAndWriteEveryKindOfJSON() throws {
        let text = #"{"a":[1,2.5,"x",true,false,null],"b":{"c":{}},"d":""}"#
        let value = try decode(JSONValue.self, from: text)
        #expect(value == .object([
            "a": .array([.number(1), .number(2.5), .string("x"), .bool(true), .bool(false), .null]),
            "b": .object(["c": .object([:])]),
            "d": .string(""),
        ]))
        #expect(try json(value) == text)
    }

    @Test func aWholeNumberIsWrittenWithoutADecimalPoint() throws {
        #expect(try json(JSONValue.number(42)) == "42")
        #expect(try json(JSONValue.array([.number(0), .number(-3)])) == "[0,-3]")
    }

    @Test func aNumberJSONCannotWriteFailsToEncode() {
        #expect(throws: (any Error).self) { try LineCodec.encode(JSONValue.number(.nan)) }
        #expect(throws: (any Error).self) { try LineCodec.encode(JSONValue.number(.infinity)) }
    }

    @Test func aCommandHasANameForTheLog() {
        #expect(MantelCommand.ping.name == "ping")
        #expect(MantelCommand.version.name == "version")
        #expect(MantelCommand.openSettings(.about).name == "settings")
        #expect(MantelCommand.diagnostics.name == "diagnostics")
        #expect(MantelCommand.show(.hidden).name == "show")
        #expect(MantelCommand.focus(.toggle).name == "focus")
        #expect(MantelCommand.refresh.name == "refresh")
        #expect(MantelCommand.reset.name == "reset")
        #expect(MantelCommand.engine.name == "engine")
        // The probe's name, never its options, which are the caller's words.
        #expect(MantelCommand.probe(.layoutMove, options: ["secret": "x"]).name == "probe layout-move")
    }
}
