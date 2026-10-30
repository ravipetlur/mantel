import CoreFoundation
import Foundation
import MKCore
import Testing

@Suite("PlistValue", .timeLimit(.minutes(2)))
struct PlistValueTests {
    /// Whole seconds, so that the XML property list format (which writes dates to the second) keeps them.
    private static let someDate = Date(timeIntervalSince1970: 1_700_000_000)
    private static let someData = Data([0x00, 0x01, 0x02, 0xFF])

    /// One of each case, and each container holding every case.
    private static let scalars: [PlistValue] = [
        .string("Mantel"), .string(""), .integer(-7), .integer(0), .integer(Int.max), .integer(Int.min),
        .real(2.5), .real(2.0), .real(0), .bool(true), .bool(false), .date(someDate), .data(someData), .data(Data()),
    ]
    private static let nested: PlistValue = .dictionary([
        "scalars": .array(scalars),
        "inner": .dictionary(["list": .array([.dictionary(["deep": .array([.integer(1), .bool(true)])]), .array([])])]),
        "empty": .dictionary([:]),
    ])
    private static let every: [PlistValue] = scalars + [.array(scalars), .dictionary(["a": .integer(1)]), nested]

    // MARK: Property list round trip

    @Test(arguments: every) func everyCaseRoundTripsThroughAPropertyList(value: PlistValue) {
        #expect(PlistValue(propertyList: value.propertyList) == value)
    }

    @Test func nestedContainersKeepTheirShapeAndTypes() throws {
        let tree = try #require(Self.nested.propertyList as? [String: Any])
        let scalars = try #require(tree["scalars"] as? [Any])
        #expect(scalars.count == Self.scalars.count)
        let inner = try #require(tree["inner"] as? [String: Any])
        let list = try #require(inner["list"] as? [Any])
        let first = try #require(list.first as? [String: Any])
        let deep = try #require(first["deep"] as? [Any])
        #expect(deep.count == 2)
        #expect(PlistValue(propertyList: tree) == Self.nested)
    }

    @Test func realsThatLookWholeStayReals() {
        #expect(PlistValue(propertyList: PlistValue.real(2.0).propertyList) == .real(2.0))
        #expect(PlistValue(propertyList: PlistValue.integer(2).propertyList) == .integer(2))
    }

    // MARK: Booleans

    /// An `NSNumber` that holds a boolean is a different thing from one that holds 1: the layout and approval tables
    /// keep both kinds, and writing a flag back as a number (or a number as a flag) changes what macOS reads.
    @Test func numberBooleansDecodeAsBoolNotInteger() {
        #expect(PlistValue(propertyList: NSNumber(value: true)) == .bool(true))
        #expect(PlistValue(propertyList: NSNumber(value: false)) == .bool(false))
        #expect(PlistValue(propertyList: kCFBooleanTrue as Any) == .bool(true))
        #expect(PlistValue(propertyList: kCFBooleanFalse as Any) == .bool(false))
        #expect(PlistValue(propertyList: true as Any) == .bool(true))
        #expect(PlistValue(propertyList: false as Any) == .bool(false))

        #expect(PlistValue(propertyList: NSNumber(value: 1)) == .integer(1))
        #expect(PlistValue(propertyList: NSNumber(value: 0)) == .integer(0))
        #expect(PlistValue(propertyList: NSNumber(value: Int8(1))) == .integer(1))
        #expect(PlistValue(propertyList: 1 as Any) == .integer(1))
        #expect(PlistValue(propertyList: 0 as Any) == .integer(0))
    }

    @Test func booleansAreWrittenAsBooleansAndIntegersAsIntegers() throws {
        let flag = try #require(PlistValue.bool(true).propertyList as? NSNumber)
        #expect(CFGetTypeID(flag) == CFBooleanGetTypeID())
        let off = try #require(PlistValue.bool(false).propertyList as? NSNumber)
        #expect(CFGetTypeID(off) == CFBooleanGetTypeID())
        let one = try #require(PlistValue.integer(1).propertyList as? NSNumber)
        #expect(CFGetTypeID(one) == CFNumberGetTypeID())
        #expect(CFGetTypeID(one) != CFBooleanGetTypeID())
    }

    @Test func numbersAreIntegersOrRealsBySizeAndKind() {
        #expect(PlistValue(propertyList: NSNumber(value: 1.5)) == .real(1.5))
        #expect(PlistValue(propertyList: NSNumber(value: 2.0)) == .real(2.0))
        #expect(PlistValue(propertyList: NSNumber(value: Float(0.5))) == .real(0.5))
        #expect(PlistValue(propertyList: NSNumber(value: Int64.min)) == .integer(Int.min))
        #expect(PlistValue(propertyList: NSNumber(value: UInt8.max)) == .integer(255))
        // Bigger than the 64-bit signed integers a property list holds; the largest one that fits is kept.
        #expect(PlistValue(propertyList: NSNumber(value: UInt64.max)) == nil)
        #expect(PlistValue(propertyList: NSNumber(value: UInt64(Int64.max) + 1)) == nil)
        #expect(PlistValue(propertyList: NSNumber(value: UInt64(Int64.max))) == .integer(Int.max))
    }

    // MARK: Through real property list files

    @Test(arguments: [PropertyListSerialization.PropertyListFormat.xml, .binary])
    func survivesAPropertyListFile(format: PropertyListSerialization.PropertyListFormat) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: Self.nested.propertyList, format: format, options: 0)
        let read = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        #expect(PlistValue(propertyList: read) == Self.nested)
    }

    // MARK: What isn't a property list value

    @Test func valuesThatAreNotPropertyListTypesAreRefused() {
        #expect(PlistValue(propertyList: NSNull()) == nil)
        #expect(PlistValue(propertyList: URL(filePath: "/tmp")) == nil)
        #expect(PlistValue(propertyList: UUID()) == nil)
        #expect(PlistValue(propertyList: [1, NSNull()] as [Any]) == nil, "one bad element refuses the whole array")
        #expect(PlistValue(propertyList: ["a": ["b": NSNull()]] as [String: Any]) == nil)
        #expect(PlistValue(propertyList: [1: "one"] as [Int: String]) == nil, "keys must be strings")
    }

    // MARK: Codable

    @Test(arguments: every) func everyCaseRoundTripsThroughJSON(value: PlistValue) throws {
        // A plain encoder and decoder: the format doesn't depend on how the journal or the store sets theirs up.
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(PlistValue.self, from: data) == value)
    }

    @Test func datesAreISO8601AndDataIsBase64() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        #expect(try String(decoding: encoder.encode(PlistValue.date(Self.someDate)), as: UTF8.self)
            == #"{"date":"2023-11-14T22:13:20.000Z"}"#)
        #expect(try String(decoding: encoder.encode(PlistValue.data(Self.someData)), as: UTF8.self)
            == #"{"data":"AAEC/w=="}"#)
    }

    @Test func eachCaseIsATaggedValueSoIntegersAndRealsStayApart() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func json(_ value: PlistValue) throws -> String { try String(decoding: encoder.encode(value), as: UTF8.self) }
        #expect(try json(.string("a")) == #"{"string":"a"}"#)
        #expect(try json(.integer(2)) == #"{"integer":2}"#)
        #expect(try json(.bool(true)) == #"{"bool":true}"#)
        #expect(try json(.array([.integer(1), .bool(false)])) == #"{"array":[{"integer":1},{"bool":false}]}"#)
        #expect(try json(.dictionary(["k": .string("v")])) == #"{"dictionary":{"k":{"string":"v"}}}"#)
        // A real with no fraction is written as `2`, and still comes back a real.
        #expect(try JSONDecoder().decode(PlistValue.self, from: Data(#"{"real":2}"#.utf8)) == .real(2.0))
        #expect(try JSONDecoder().decode(PlistValue.self, from: Data(#"{"integer":2}"#.utf8)) == .integer(2))
    }

    @Test func dateWithoutFractionalSecondsIsAccepted() throws {
        let value = try JSONDecoder().decode(PlistValue.self, from: Data(#"{"date":"2023-11-14T22:13:20Z"}"#.utf8))
        #expect(value == .date(Self.someDate))
    }

    @Test func millisecondsAreKept() throws {
        let precise = PlistValue.date(Date(timeIntervalSince1970: 1_700_000_000.125))
        let data = try JSONEncoder().encode(precise)
        #expect(try JSONDecoder().decode(PlistValue.self, from: data) == precise)
    }

    @Test(arguments: [
        #"{}"#,
        #"{"bogus":1}"#,
        #"{"string":"a","integer":1}"#,
        #"{"string":5}"#,
        #"{"date":"yesterday"}"#,
        #"{"data":"not base64!"}"#,
        #"{"array":[{"bogus":1}]}"#,
        #"[]"#,
    ])
    func malformedJSONIsRefused(json: String) {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PlistValue.self, from: Data(json.utf8)) }
    }
}
