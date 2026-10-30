/// A release version: three non-negative whole numbers, `X.Y.Z`. They compare as numbers, not as text, so 1.10.0 is
/// newer than 1.9.9.
public struct VersionNumber: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// Reads `X.Y.Z` or `vX.Y.Z`: exactly three numbers of plain digits, separated by dots, with no leading zeros, no
    /// sign, no spaces and nothing after them (so no `-beta` or `+build`). Anything else is nil.
    public init?(_ string: String) {
        var text = Substring(string)
        if text.first == "v" { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Self.number(parts[0]), let minor = Self.number(parts[1]), let patch = Self.number(parts[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// `X.Y.Z`, without a leading `v`.
    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// One component: ASCII digits only, and a zero only on its own (never `01`). Too big for an `Int` is nil.
    private static func number(_ part: Substring) -> Int? {
        let digits = part.utf8
        guard let first = digits.first, digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return nil }
        guard first != UInt8(ascii: "0") || digits.count == 1 else { return nil }
        return Int(part)
    }
}
