import Foundation

/// What the two pickers of Settings › General › Revealing offer, and what each choice is called.
public enum RevealChoices {
    /// A choice in a picker: the value it sets, and its name.
    public struct Option<Value: Hashable & Sendable>: Sendable, Identifiable {
        public let value: Value
        public let title: String

        public var id: Value { value }

        public init(value: Value, title: String) {
            self.value = value
            self.title = title
        }
    }

    /// "Delay before showing": 0.1 s, 0.2 s, 0.3 s, 0.5 s and 0.8 s.
    public static let hoverDelays: [Option<Int>] = RevealSettings.hoverDelayChoices.map {
        Option(value: $0, title: hoverDelayTitle(milliseconds: $0))
    }

    /// "Hide again after": 5, 10, 15 and 30 seconds, 1 minute, and never.
    public static let rehideDelays: [Option<RehideDelay>] =
        RehideDelay.choices.map { Option(value: .seconds($0), title: rehideTitle(.seconds($0))) }
        + [Option(value: .never, title: rehideTitle(.never))]

    /// "0.3 s" for 300 milliseconds. A number that isn't a whole tenth of a second (a choice may be added) is given in milliseconds.
    /// (Always with a point, whatever the language: the digits are a measurement, not a sentence.)
    public static func hoverDelayTitle(milliseconds: Int) -> String {
        guard milliseconds > 0, milliseconds % 100 == 0 else { return "\(milliseconds) ms" }
        let tenths = milliseconds / 100
        return "\(tenths / 10).\(tenths % 10) s"
    }

    /// "10 seconds", "1 minute", "Never".
    public static func rehideTitle(_ delay: RehideDelay) -> String {
        switch delay {
        case .never: "Never"
        case .seconds(let seconds) where seconds % 60 == 0:
            seconds == 60 ? "1 minute" : "\(seconds / 60) minutes"
        case .seconds(let seconds): seconds == 1 ? "1 second" : "\(seconds) seconds"
        }
    }
}
