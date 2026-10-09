/// Which displays are connected, whatever their order or arrangement: the UUIDs, sorted. A saved menu bar layout is
/// kept per fingerprint, so plugging the same monitors back in finds it again.
public struct DisplayFingerprint: Codable, Hashable, Sendable {
    /// The displays' UUIDs, sorted.
    public let uuids: [String]

    /// The fingerprint of these UUIDs, in any order.
    public init(uuids: [String]) {
        self.uuids = uuids.sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case uuids
    }

    /// Sorts what it reads, so a stored fingerprint written by hand or by another version is still equal to the same
    /// set of displays.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(uuids: try container.decode([String].self, forKey: .uuids))
    }
}
