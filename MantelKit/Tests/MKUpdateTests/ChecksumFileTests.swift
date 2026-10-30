import Foundation
import MKTestSupport
import MKUpdate
import Testing

/// The checksum file a release publishes, and the hashing the download is held to before anything is mounted or installed.
@Suite("The checksum file", .timeLimit(.minutes(2)))
struct ChecksumFileTests {
    let name = "Mantel-1.2.0.dmg"
    /// SHA-256 of the three bytes "abc" (FIPS 180-4 example), and of nothing.
    let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    let nothing = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let other = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    let folder = TemporaryFolder(prefix: "mantel-checksum")

    func hash(in text: String, for file: String? = nil) -> String? {
        ChecksumFile.expectedHash(in: text, forFile: file ?? name)
    }

    // MARK: Parsing

    @Test(arguments: [
        "ABC  NAME\n", "ABC  NAME", "ABC NAME\n", "ABC *NAME\n", "ABC  *NAME\n", "ABC  NAME\r\n",
        "OTHER  Other.dmg\r\nABC  NAME\r\n", "\n\n# checksums\nnot a checksum line\n\nABC  NAME\n\ntrailing words\n",
        "ABC  NAME\nABC *NAME\n",
    ])
    func readsTheHashFromShasumsFormat(template: String) {
        let text = template.replacingOccurrences(of: "ABC", with: abc).replacingOccurrences(of: "OTHER", with: other)
            .replacingOccurrences(of: "NAME", with: name)
        #expect(hash(in: text) == abc)
    }

    @Test func upperCaseHexIsReturnedInLowerCase() {
        #expect(hash(in: "\(abc.uppercased())  \(name)\n") == abc)
    }

    /// The name matches exactly: another case, a path, a suffix, another version all give nothing.
    @Test(arguments: [
        "mantel-1.2.0.dmg", "Mantel-1.2.0.dmg.sha256", "Mantel-1.2.0", "antel-1.2.0.dmg", "Mantel-1.2.0.dmg ", "./Mantel-1.2.0.dmg",
        "dist/Mantel-1.2.0.dmg", "Mantel-1.2.1.dmg", "",
    ])
    func theNameMustMatchExactly(asked: String) {
        #expect(hash(in: "\(abc)  \(name)\n", for: asked) == nil)
        #expect(hash(in: "\(abc)  \(name).zip\n") == nil)
        #expect(hash(in: "\(abc)  x\(name)\n") == nil)
    }

    /// Anything but 64 hex digits, then one or two spaces (and an optional star), then a name, isn't an entry.
    @Test(arguments: [
        String(repeating: "a", count: 63) + "  NAME", String(repeating: "a", count: 65) + "  NAME", "  NAME",
        String(repeating: "g", count: 64) + "  NAME", String(repeating: "\u{ff41}", count: 64) + "  NAME",
        "ABC\tNAME", "ABC   NAME", "ABC   *NAME", "ABC\u{a0}NAME", "ABC = NAME", "ABCNAME", " ABC  NAME", "ABC  ", "ABC  *", "ABC",
        "SHA256 (NAME) = ABC", "{\"sha256\": \"abc\"}", "<html>404</html>", "", "\n", "garbage",
    ])
    func aMalformedLineGivesNothing(template: String) {
        let text = template.replacingOccurrences(of: "ABC", with: abc).replacingOccurrences(of: "NAME", with: name)
        #expect(hash(in: text + "\n") == nil)
    }

    @Test func twoDifferentHashesForTheSameNameAreAmbiguous() {
        #expect(hash(in: "\(abc)  \(name)\n\(other)  \(name)\n") == nil)
        // A malformed line for the name isn't an entry, so it doesn't make the real one ambiguous.
        #expect(hash(in: "\(String(abc.dropLast()))  \(name)\n\(other)  \(name)\n") == other)
    }

    // MARK: Hashing

    @Test func hashesKnownDataAndMatchesOnlyTheRightHash() {
        #expect(ChecksumFile.sha256(of: Data("abc".utf8)) == abc)
        #expect(ChecksumFile.sha256(of: Data()) == nothing)
        let data = Data("abc".utf8)
        #expect(ChecksumFile.matches(data, expectedHash: abc))
        #expect(ChecksumFile.matches(data, expectedHash: abc.uppercased()))
        for wrong in [other, nothing, "", String(abc.dropLast()), abc + "0"] {
            #expect(!ChecksumFile.matches(data, expectedHash: wrong))
        }
    }

    /// Deterministic bytes that don't repeat on a power-of-two boundary, so a chunking mistake changes the hash.
    func pattern(count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 31) ^ ($0 >> 8) ^ ($0 >> 17)) })
    }

    @Test(arguments: [0, 1, 1_048_575, 1_048_576, 1_048_577, 2_621_443])
    func aFileIsStreamedToTheSameHashAsItsBytes(size: Int) throws {
        let bytes = pattern(count: size)
        let url = folder.url.appending(path: "blob.bin", directoryHint: .notDirectory)
        try bytes.write(to: url)
        #expect(try ChecksumFile.sha256(ofFileAt: url) == ChecksumFile.sha256(of: bytes))
    }

    @Test func aFileMatchesItsPublishedChecksumAndNoOtherFile() throws {
        let bytes = pattern(count: 1_500_000)
        let published = "\(ChecksumFile.sha256(of: bytes))  \(name)\n"
        let expected = try #require(hash(in: published))
        let dmg = folder.url.appending(path: name, directoryHint: .notDirectory)
        try bytes.write(to: dmg)
        #expect(try ChecksumFile.matches(fileAt: dmg, expectedHash: expected))
        // One changed byte, and a truncated file.
        var changed = bytes
        changed[1_234_567] ^= 0x01
        try changed.write(to: dmg)
        #expect(try !ChecksumFile.matches(fileAt: dmg, expectedHash: expected))
        try bytes.dropLast().write(to: dmg)
        #expect(try !ChecksumFile.matches(fileAt: dmg, expectedHash: expected))
    }

    /// A file that can't be read is an error, not a mismatch.
    @Test func aMissingFileOrAFolderThrows() {
        #expect(throws: (any Error).self) { try ChecksumFile.sha256(ofFileAt: folder.url.appending(path: "nope.dmg")) }
        #expect(throws: (any Error).self) { try ChecksumFile.sha256(ofFileAt: folder.url) }
    }
}
