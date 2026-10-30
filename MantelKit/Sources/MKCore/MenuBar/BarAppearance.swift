import Foundation

/// Whether the menu bar is light or dark behind its icons: a picture of an icon is kept for each, since a monochrome icon is drawn in
/// the colour that shows on the bar.
///
/// It is a dictionary key (images are kept per appearance), and it says how it is spelled as one (`CodingKeyRepresentable`), so that
/// a dictionary of them is saved as an object with a key for each, and not as a list of keys and values one after the other.
public enum BarAppearance: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    /// A light bar, with dark glyphs.
    case light
    /// A dark bar, with light glyphs.
    case dark

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public var codingKey: any CodingKey {
        Key(stringValue: rawValue)
    }

    public init?<Key: CodingKey>(codingKey: Key) {
        self.init(rawValue: codingKey.stringValue)
    }
}
