import CryptoKit
import Foundation

/// The release's `.sha256` file, and SHA-256 itself.
public enum ChecksumFile {
    /// The expected hash for `name`, from a checksum file's text: lines of `<64 hex digits>  <file name>` as `shasum`
    /// writes them. One or two spaces separate the two, and a `*` may come before the name (binary mode). The digits
    /// may be upper or lower case; the answer is lower case. Other lines are skipped.
    ///
    /// The name has to match exactly. Nil when no line is for `name`, or when lines for it disagree on the hash.
    public static func expectedHash(in text: String, forFile name: String) -> String? {
        guard !name.isEmpty else { return nil }
        var hashes: Set<String> = []
        for line in text.split(whereSeparator: \.isNewline) {
            if let entry = entry(in: line), entry.name == name { hashes.insert(entry.hash) }
        }
        return hashes.count == 1 ? hashes.first : nil
    }

    /// The lower case hex SHA-256 of `data`. This holds all of it in memory: for a disk image use
    /// `sha256(ofFileAt:)`.
    public static func sha256(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// The lower case hex SHA-256 of a file, read a megabyte at a time, so a disk image is never held whole in memory.
    /// It reads the whole file, so call it off the main actor. Throws when the file can't be opened or read.
    public static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var reading = true
        while reading {
            reading = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                return true
            }
        }
        return hex(hasher.finalize())
    }

    /// Whether `data` hashes to `expectedHash`, in either case.
    public static func matches(_ data: Data, expectedHash: String) -> Bool {
        sha256(of: data) == expectedHash.lowercased()
    }

    /// Whether the file hashes to `expectedHash`, in either case, streaming it as `sha256(ofFileAt:)` does. Throws
    /// when the file can't be read, which is not the same as a mismatch.
    public static func matches(fileAt url: URL, expectedHash: String) throws -> Bool {
        try sha256(ofFileAt: url) == expectedHash.lowercased()
    }

    // MARK: Parsing

    private static let chunkSize = 1 << 20
    private static let hashLength = 64

    /// One line: 64 hex digits, one or two spaces, an optional `*`, then the name.
    private static func entry(in line: Substring) -> (hash: String, name: String)? {
        let bytes = Array(line.utf8)
        guard bytes.count > hashLength, bytes[..<hashLength].allSatisfy(isHexDigit) else { return nil }
        var index = hashLength
        while index < bytes.count, bytes[index] == UInt8(ascii: " ") { index += 1 }
        guard (1...2).contains(index - hashLength) else { return nil }
        if index < bytes.count, bytes[index] == UInt8(ascii: "*") { index += 1 }
        guard index < bytes.count else { return nil }
        let hash = String(decoding: bytes[..<hashLength], as: UTF8.self).lowercased()
        return (hash, String(decoding: bytes[index...], as: UTF8.self))
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "f"), UInt8(ascii: "A")...UInt8(ascii: "F"): true
        default: false
        }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(SHA256.byteCount * 2)
        for byte in digest {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
