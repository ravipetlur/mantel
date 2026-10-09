import Foundation
import MKCommands
import Testing

@Suite("Line codec")
struct LineCodecTests {
    private func lines(_ outputs: [LineCodecOutput]) -> [String] {
        outputs.map {
            switch $0 {
            case .line(let data): String(decoding: data, as: UTF8.self)
            case .overlong: "<overlong>"
            }
        }
    }

    @Test func splitsMultipleLinesInOneChunk() {
        var codec = LineCodec()
        let outputs = codec.append(Data("one\ntwo\nthree\n".utf8))
        #expect(lines(outputs) == ["one", "two", "three"])
    }

    @Test func keepsPartialLine() {
        var codec = LineCodec()
        #expect(codec.append(Data("one\ntw".utf8)).count == 1)
        #expect(codec.append(Data("o".utf8)).isEmpty)
        #expect(lines(codec.append(Data("\nthr".utf8))) == ["two"])
        #expect(lines(codec.append(Data("ee\n".utf8))) == ["three"])
    }

    @Test func aLineArrivingOneByteAtATimeIsOneLine() {
        var codec = LineCodec()
        var all: [LineCodecOutput] = []
        for byte in Array("{\"a\":1}\n{\"b\":2}\n".utf8) {
            all += codec.append(Data([byte]))
        }
        #expect(lines(all) == [#"{"a":1}"#, #"{"b":2}"#])
    }

    @Test func aMultiByteCharacterSplitAcrossChunksIsKeptWhole() {
        var codec = LineCodec()
        let bytes = Array("é\n".utf8)
        #expect(codec.append(Data(bytes[..<1])).isEmpty)
        #expect(lines(codec.append(Data(bytes[1...]))) == ["é"])
    }

    @Test func anEmptyLineIsALine() {
        var codec = LineCodec()
        #expect(lines(codec.append(Data("\nx\n".utf8))) == ["", "x"])
    }

    @Test func nothingIsLeftOverAfterACompleteLine() {
        var codec = LineCodec()
        #expect(codec.append(Data("a\n".utf8)).count == 1)
        #expect(codec.append(Data()).isEmpty)
    }

    @Test func overlongLineIsRejected() {
        var codec = LineCodec()
        let tooLong = Data(repeating: UInt8(ascii: "x"), count: LineCodec.maxLineBytes + 1)
        let outputs = codec.append(tooLong + Data("\n{\"next\":1}\n".utf8))
        #expect(lines(outputs) == ["<overlong>", #"{"next":1}"#])
    }

    @Test func aLineOfExactlyTheLimitIsAccepted() {
        var codec = LineCodec()
        let atLimit = Data(repeating: UInt8(ascii: "y"), count: LineCodec.maxLineBytes)
        let outputs = codec.append(atLimit + Data("\n".utf8))
        #expect(outputs == [.line(atLimit)])
    }

    @Test func overlongLineArrivingInPiecesIsReportedOnceAndTheRestIsSkipped() {
        var codec = LineCodec()
        let piece = Data(repeating: UInt8(ascii: "z"), count: LineCodec.maxLineBytes / 2 + 1)
        // Two pieces already pass the limit, and it is said at once: no waiting for a newline that may never come.
        #expect(codec.append(piece).isEmpty)
        #expect(codec.append(piece) == [.overlong])
        // The rest of that line, however long, is dropped without another report.
        #expect(codec.append(piece).isEmpty)
        #expect(codec.append(piece).isEmpty)
        // Its newline ends the skipping, and the next line is read.
        #expect(lines(codec.append(Data("tail\nnext\n".utf8))) == ["next"])
    }

    @Test func twoOverlongLinesAreReportedTwice() {
        var codec = LineCodec()
        let tooLong = Data(repeating: UInt8(ascii: "x"), count: LineCodec.maxLineBytes + 1) + Data("\n".utf8)
        #expect(codec.append(tooLong + tooLong + Data("ok\n".utf8)) == [.overlong, .overlong, .line(Data("ok".utf8))])
    }

    @Test func encodeHasNoEmbeddedNewlines() throws {
        let command = MantelCommand.probe(.inventory, options: ["note": "two\nlines\r\nand a separator \u{2028}"])
        let data = try LineCodec.encode(RequestEnvelope(id: UUID(), command: command))
        #expect(data.last == UInt8(ascii: "\n"))
        #expect(data.dropLast().contains(UInt8(ascii: "\n")) == false)
        #expect(data.dropLast().contains(UInt8(ascii: "\r")) == false)

        // And it reads back as the one line it is.
        var codec = LineCodec()
        let outputs = codec.append(data)
        #expect(outputs.count == 1)
        guard case .line(let line) = outputs[0] else {
            Issue.record("expected a line")
            return
        }
        #expect(try JSONDecoder().decode(RequestEnvelope.self, from: line).command == command)
    }

    @Test func encodeIsCompactAndOrdered() throws {
        let data = try LineCodec.encode(JSONValue.object(["b": .number(1), "a": .string("x/y")]))
        #expect(String(decoding: data, as: UTF8.self) == "{\"a\":\"x/y\",\"b\":1}\n")
    }
}
