import Foundation
import MKCommands
import MKLayout

extension RevealEvent {
    /// What `mantel show` says to the reveal: that much is shown, whatever is showing, or (for none) all of it is put away.
    public static func forShow(_ target: ShowTarget) -> RevealEvent {
        switch target {
        case .hidden: .show(.hidden)
        case .all: .show(.all)
        case .nothing: .show(.off)
        }
    }

    /// What `mantel focus` says to the reveal.
    public static func forFocus(_ change: FocusChange) -> RevealEvent {
        switch change {
        case .on: .setFocusMode(true)
        case .off: .setFocusMode(false)
        case .toggle: .toggleFocusMode
        }
    }
}

extension EngineStatus {
    /// What `mantel engine` answers with: the engine in use (its raw value and its title), why, whether it only works approximately,
    /// and how each engine stands (its raw value to a sentence).
    public var commandValue: JSONValue {
        .object([
            "engine": .string(kind.rawValue),
            "title": .string(kind.title),
            "reason": .string(reason),
            "degraded": .bool(degraded),
            "availability": .object(Dictionary(uniqueKeysWithValues: availability.map { ($0.key.rawValue, JSONValue.string($0.value)) })),
        ])
    }
}
