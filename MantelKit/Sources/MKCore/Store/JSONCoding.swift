import Foundation

/// How dates are written in Mantel's files: ISO 8601 in UTC, to the millisecond (`2026-10-08T12:30:00.250Z`).
/// Reading also accepts a date without fractional seconds.
package enum ISO8601Dates {
    package static func string(from date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    package static func date(from string: String) -> Date? {
        (try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(string, strategy: Date.ISO8601FormatStyle()))
    }
}

/// The encoder and decoder for the settings and journal files: sorted keys and pretty printing, so a file diffs and reads
/// well; ISO 8601 dates; base64 data (the `JSONEncoder` default).
package enum JSONCoding {
    package static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601Dates.string(from: date))
        }
        return encoder
    }

    package static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = ISO8601Dates.date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "\"\(string)\" is not an ISO 8601 date")
            }
            return date
        }
        return decoder
    }
}
