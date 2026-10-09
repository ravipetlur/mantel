import Foundation

/// The options a probe is run with, as the command line gave them (`--hold 10 --apps com.a,com.b --allow-any`).
public struct ProbeOptions: Sendable, Equatable {
    /// The most numbers `numbers(_:)` gives back, so that `0-999999999` can't ask for a billion of them.
    static let maximumNumbers = 1024

    private let raw: [String: String]

    public init(_ raw: [String: String]) {
        self.raw = raw
    }

    /// `--allow-any`: the probe may touch apps other than the test item. Only the word `true` or `1` switches it on.
    public var allowAny: Bool {
        guard let value = string("allow-any")?.lowercased() else { return false }
        return value == "true" || value == "1"
    }

    /// The option's text, trimmed; nil when it isn't there or is only spaces.
    public func string(_ key: String) -> String? {
        guard let value = raw[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// The option as a whole number inside `range`: a number outside it is moved to the nearest end of it, and one that isn't
    /// a number (or isn't there) is `defaultValue`.
    public func int(_ key: String, default defaultValue: Int, range: ClosedRange<Int>) -> Int {
        guard let text = string(key), let number = Int(text) else { return defaultValue }
        return min(max(number, range.lowerBound), range.upperBound)
    }

    /// A comma-separated option as its parts, trimmed, with the empty ones left out.
    public func list(_ key: String) -> [String] {
        guard let text = raw[key] else { return [] }
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Whole numbers given as a range (`0-255`), a list (`2,5,6`) or both (`1-2,8`). Nil when the option isn't there or any of
    /// it isn't a number; at most `maximumNumbers` of them.
    public func numbers(_ key: String) -> [Int]? {
        guard raw[key] != nil else { return nil }
        let parts = list(key)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            switch ends.count {
            case 1:
                guard let value = ends[0] else { return nil }
                numbers.append(value)
            case 2:
                guard let first = ends[0], let second = ends[1] else { return nil }
                let low = min(first, second), high = max(first, second)
                numbers.append(contentsOf: (low...min(high, low + Self.maximumNumbers)))
            default:
                return nil
            }
            if numbers.count >= Self.maximumNumbers { return Array(numbers.prefix(Self.maximumNumbers)) }
        }
        return numbers
    }
}

/// Why a probe wasn't run.
public struct ProbeRefusal: Error, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// Which apps and system items a probe that changes something may touch. By default only the test item, so that a probe never alters the
/// person's own menu bar; `--allow-any` lifts that.
public enum ProbeSafety {
    public static let fixtureBundleIDSuffix = ".testitem"

    /// `bundleIDs` if each is the test item's (its bundle ID ends with the suffix) or `--allow-any` was given; otherwise the
    /// refusal, which names the first that isn't.
    public static func permitted(_ bundleIDs: [String], options: ProbeOptions) -> Result<[String], ProbeRefusal> {
        guard !options.allowAny else { return .success(bundleIDs) }
        if let other = bundleIDs.first(where: { !$0.hasSuffix(fixtureBundleIDSuffix) }) {
            return .failure(ProbeRefusal(message: "This probe only touches MantelTestItem. Add --allow-any to touch \(other)."))
        }
        return .success(bundleIDs)
    }

    /// `systemItems` if they are every system item (0 to 255, and any more), which hides none of them, or `--allow-any` was
    /// given; otherwise the refusal. An allowlist that names fewer conceals the rest: the clock, Control Center, Wi-Fi.
    public static func permittedSystemItems(_ systemItems: [Int], options: ProbeOptions) -> Result<[Int], ProbeRefusal> {
        guard !options.allowAny, !Set(0...255).isSubset(of: systemItems) else { return .success(systemItems) }
        return .failure(ProbeRefusal(message: "This probe only hides MantelTestItem. Add --allow-any to hide system items."))
    }

    /// Why Mantel's own item is never one a probe hides, whatever the options say: the probe's allowlist always has it.
    public static let ownItemMessage = "Mantel's own item is never hidden by a probe."
}
