import Foundation

/// What `LineCodec` found in the bytes it was given.
public enum LineCodecOutput: Sendable, Equatable {
    /// One complete line, without its newline.
    case line(Data)
    /// A line longer than `LineCodec.maxLineBytes`. It has been dropped, and so is the rest of it, up to the next newline.
    case overlong
}

/// Splits a stream of bytes into lines: Mantel's messages are one JSON object per line, UTF-8, ended by `"\n"`.
///
/// Bytes arrive in pieces of any size, so a codec is kept for as long as a connection lasts and each piece is
/// `append`ed to it. A line that is only partly there is kept for the next piece.
public struct LineCodec: Sendable {
    /// The longest line allowed, not counting its newline: 1 MiB.
    public static let maxLineBytes = 1 << 20

    /// The start of the line that hasn't ended yet.
    private var pending: [UInt8] = []
    /// True from the moment a line is found too long until its newline arrives: what comes meanwhile is dropped.
    private var skipping = false

    public init() {}

    /// Adds `bytes` and returns the lines they complete, in order. A line that grows past `maxLineBytes` is reported at
    /// once, as `.overlong`, without waiting for its end, and nothing more of it is kept.
    public mutating func append(_ bytes: Data) -> [LineCodecOutput] {
        var outputs: [LineCodecOutput] = []
        let chunk = [UInt8](bytes)
        var start = 0
        while start < chunk.count {
            let newline = chunk[start...].firstIndex(of: UInt8(ascii: "\n"))
            let end = newline ?? chunk.count
            let next = newline.map { $0 + 1 } ?? chunk.count

            if skipping {
                if newline != nil { skipping = false }
            } else if pending.count + (end - start) > Self.maxLineBytes {
                outputs.append(.overlong)
                pending = []
                skipping = newline == nil
            } else {
                pending.append(contentsOf: chunk[start..<end])
                if newline != nil {
                    outputs.append(.line(Data(pending)))
                    pending.removeAll()
                }
            }
            start = next
        }
        return outputs
    }

    /// `value` as one line of JSON: compact, keys in order, and with its newline. A newline inside a string is written
    /// as `\n`, so the only newline in the result is the last byte.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
