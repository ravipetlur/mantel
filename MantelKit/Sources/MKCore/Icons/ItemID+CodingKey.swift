/// A dictionary keyed by `ItemID` is written as a JSON object keyed by each ID's text form (`{"com.example.app#0": …}`), not as the
/// flat list of keys and values that the encoder makes of a dictionary whose keys it doesn't know to be strings.
///
/// Reading is the other way round: a key that isn't the text form of any ID makes no `ItemID` (`init(string:)` is nil), which a
/// reader that wants to go on without it (`IconPreferences`) decodes as plain text and sorts out itself.
extension ItemID: CodingKeyRepresentable {
    private struct StringKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public var codingKey: any CodingKey { StringKey(stringValue: string) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(string: codingKey.stringValue)
    }
}
