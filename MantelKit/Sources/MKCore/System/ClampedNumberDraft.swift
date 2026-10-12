import Foundation

/// What a number field holds while it is being edited, kept apart from the number it stands for: **typing never changes the number**.
///
/// The text is the person's until the field is committed (Return, or leaving the field). Only then is it read: as a whole number, brought
/// within the range and onto the step of its `format`, and handed back to be saved. A text that isn't a number changes nothing, and the field
/// goes back to the number it had. A number that is changed some other way (a stepper beside the field) is taken as it is, and the text
/// follows it.
///
/// A field that is bound straight to its number through a format reads its text on every key, and so brings "1" to 1000 before a second
/// digit can be typed.
public struct ClampedNumberDraft: Sendable, Equatable {
    public let format: ClampedIntegerFormat
    /// The number the field stands for: the last one committed, or the last one it was given.
    public private(set) var committed: Int
    /// What the field shows. The field writes it as the person types; nothing reads it but `commit`.
    public var text: String

    public init(committed: Int, format: ClampedIntegerFormat) {
        self.format = format
        self.committed = committed
        text = format.format(committed)
    }

    /// The field is committed. Returns the number to save when the text says one that isn't the number the field already stands for;
    /// nil when it doesn't (not a number, or the same one). Either way the text ends as the number that stands.
    public mutating func commit() -> Int? {
        defer { text = format.format(committed) }
        guard let number = try? format.parseStrategy.parse(text), number != committed else { return nil }
        committed = number
        return number
    }

    /// The number was changed from outside the field, and the text follows it.
    public mutating func follow(_ number: Int) {
        committed = number
        text = format.format(number)
    }
}
