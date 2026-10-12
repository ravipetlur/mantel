import Foundation

/// A whole number as a text field shows it: written as plain digits, and read back within a range, on a step.
///
/// What is read is brought within `range` (and on the nearest step). A text that isn't a number is refused.
///
/// **A text field must not be bound to a number through this** (`TextField(value:format:)`): SwiftUI's text field reads its text on every
/// key, so a number half typed is changed as it is typed (1 becomes 1000, and no number can be typed). A field holds its text apart and
/// reads it when it is committed, with `ClampedNumberDraft`, which does that with this format.
public struct ClampedIntegerFormat: ParseableFormatStyle, Sendable {
    public typealias FormatInput = Int
    public typealias FormatOutput = String

    public let range: ClosedRange<Int>
    /// The numbers are `range.lowerBound` and every `step` after it; 1 for any whole number.
    public let step: Int

    public init(range: ClosedRange<Int>, step: Int = 1) {
        self.range = range
        self.step = max(step, 1)
    }

    public func format(_ value: Int) -> String {
        String(value)
    }

    public var parseStrategy: Strategy {
        Strategy(range: range, step: step)
    }

    /// The number `value` is read as: within `range`, and on the nearest step (the higher of two that are equally near).
    public static func clamped(_ value: Int, to range: ClosedRange<Int>, step: Int) -> Int {
        let step = max(step, 1)
        let within = min(max(value, range.lowerBound), range.upperBound)
        let steps = ((within - range.lowerBound) * 2 + step) / (2 * step)
        // The last step may fall past the end of a range that isn't a whole number of steps long.
        return min(range.lowerBound + steps * step, range.upperBound)
    }

    public struct Strategy: ParseStrategy, Sendable {
        public let range: ClosedRange<Int>
        public let step: Int

        /// The text isn't a whole number.
        public struct NotANumber: Error, Equatable {}

        public func parse(_ value: String) throws -> Int {
            // Spaces and the marks that group digits are left out, so that "3 000" and "3,000" are read as 3000.
            let ignored = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",’'"))
            let text = String(String.UnicodeScalarView(value.unicodeScalars.filter { !ignored.contains($0) }))
            let digits = text.hasPrefix("-") || text.hasPrefix("+") ? String(text.dropFirst()) : text
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw NotANumber() }
            // A number too long for an `Int` is still a number: it is as far past the range as can be.
            let number = Int(text) ?? (text.hasPrefix("-") ? Int.min : Int.max)
            return ClampedIntegerFormat.clamped(number, to: range, step: step)
        }
    }
}
