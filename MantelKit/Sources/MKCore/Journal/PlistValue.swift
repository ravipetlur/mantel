import CoreFoundation
import Foundation

/// A property list value that is `Sendable`, `Equatable` and `Codable`, for what the journal keeps of a value Mantel is
/// about to change in a plist file or in the preferences.
///
/// - `init?(propertyList:)` and `propertyList` convert to and from what `PropertyListSerialization` and
///   `CFPreferences` hand out and take in.
/// - `Codable` writes one key, the case's name, holding the payload, so integers and reals, or a flag and a number,
///   can't be mixed up: `{"integer": 1}`, `{"bool": true}`. A date is an ISO 8601 string and data is base64, whatever
///   encoder is used.
public enum PlistValue: Codable, Sendable, Equatable {
    case string(String), integer(Int), real(Double), bool(Bool), date(Date), data(Data)
    case array([PlistValue]), dictionary([String: PlistValue])

    /// The value for an object from a property list, or `nil` if it, or anything inside it, isn't a property list type
    /// (or is an integer that doesn't fit in 64 bits).
    public init?(propertyList: Any) {
        switch propertyList {
        case let string as String:
            self = .string(string)
        case let date as Date:
            self = .date(date)
        case let data as Data:
            self = .data(data)
        case let array as [Any]:
            var values: [PlistValue] = []
            values.reserveCapacity(array.count)
            for element in array {
                guard let value = PlistValue(propertyList: element) else { return nil }
                values.append(value)
            }
            self = .array(values)
        case let dictionary as [String: Any]:
            var values: [String: PlistValue] = [:]
            values.reserveCapacity(dictionary.count)
            for (key, element) in dictionary {
                guard let value = PlistValue(propertyList: element) else { return nil }
                values[key] = value
            }
            self = .dictionary(values)
        case let number as NSNumber:
            // A boolean is an NSNumber too, and one that answers `intValue` and `doubleValue` like 1 and 0. Only the
            // Core Foundation type tells them apart.
            let reference = number as CFNumber
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(reference) {
                self = .real(number.doubleValue)
            } else {
                // An unsigned 64-bit number above `Int64.max` reads as a negative one, without any sign of loss.
                if String(cString: number.objCType) == "Q", number.uint64Value > UInt64(Int64.max) { return nil }
                var integer: Int64 = 0
                guard CFNumberGetValue(reference, .sInt64Type, &integer) else { return nil }
                self = .integer(Int(integer))
            }
        default:
            return nil
        }
    }

    /// The value as the objects a property list holds: `String`, `NSNumber` (a boolean one for `.bool`), `Date`, `Data`,
    /// `[Any]` and `[String: Any]`.
    public var propertyList: Any {
        switch self {
        case .string(let string): string
        case .integer(let integer): NSNumber(value: integer)
        case .real(let real): NSNumber(value: real)
        case .bool(let bool): NSNumber(value: bool)
        case .date(let date): date
        case .data(let data): data
        case .array(let values): values.map(\.propertyList)
        case .dictionary(let values): values.mapValues(\.propertyList)
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case string, integer, real, bool, date, data, array, dictionary
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "A plist value has exactly one key naming its type"))
        }
        switch key {
        case .string:
            self = .string(try container.decode(String.self, forKey: key))
        case .integer:
            self = .integer(try container.decode(Int.self, forKey: key))
        case .real:
            self = .real(try container.decode(Double.self, forKey: key))
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: key))
        case .date:
            let string = try container.decode(String.self, forKey: key)
            guard let date = ISO8601Dates.date(from: string) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container,
                                                       debugDescription: "\"\(string)\" is not an ISO 8601 date")
            }
            self = .date(date)
        case .data:
            let string = try container.decode(String.self, forKey: key)
            guard let data = Data(base64Encoded: string) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Not valid base64")
            }
            self = .data(data)
        case .array:
            self = .array(try container.decode([PlistValue].self, forKey: key))
        case .dictionary:
            self = .dictionary(try container.decode([String: PlistValue].self, forKey: key))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let string): try container.encode(string, forKey: .string)
        case .integer(let integer): try container.encode(integer, forKey: .integer)
        case .real(let real): try container.encode(real, forKey: .real)
        case .bool(let bool): try container.encode(bool, forKey: .bool)
        case .date(let date): try container.encode(ISO8601Dates.string(from: date), forKey: .date)
        case .data(let data): try container.encode(data.base64EncodedString(), forKey: .data)
        case .array(let values): try container.encode(values, forKey: .array)
        case .dictionary(let values): try container.encode(values, forKey: .dictionary)
        }
    }
}
