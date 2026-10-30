import CoreGraphics
import Foundation
import ImageIO
import MKTestSupport
import Testing
import UniformTypeIdentifiers

@testable import MKMenuBar

/// Pictures are drawn in memory and written to a folder of the test's own: nothing is read from this Mac.
@Suite("Image import", .timeLimit(.minutes(1)))
struct ImageImportTests {
    private let folder = TemporaryFolder()

    /// Where the chosen files are, and the folder the copies go to (not made: the import makes it).
    private var sources: URL { folder.url.appending(path: "Chosen", directoryHint: .isDirectory) }
    private var destination: URL { folder.url.appending(path: "OwnImages", directoryHint: .isDirectory) }

    // MARK: Pictures

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A square picture `side` pixels across, as the bytes of a PNG: a flat colour, or when `noisy` pixels that don't compress.
    private func pngData(side: Int, height: Int? = nil, noisy: Bool = false, type: UTType = .png) -> Data {
        let height = height ?? side
        var pixels = [UInt8](repeating: 0x80, count: side * height * 4)
        if noisy {
            pixels.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        }
        let image = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: side, height: height, bitsPerComponent: 8, bytesPerRow: side * 4,
                      space: Self.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A one-page PDF, 36 points square.
    private func pdfData() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 36, height: 36)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(colorSpace: Self.sRGB, components: [0.2, 0.4, 0.8, 1])!)
        context.fill(CGRect(x: 6, y: 6, width: 24, height: 24))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// Writes `data` as a file called `name` in the folder of chosen files, and gives its URL.
    @discardableResult
    private func choose(_ data: Data, as name: String) throws -> URL {
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let url = sources.appending(path: name, directoryHint: .notDirectory)
        try data.write(to: url)
        return url
    }

    private func copies() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
    }

    // MARK: Size

    @Test func refusesOverOneMegabyte() throws {
        #expect(ImageImport.maximumBytes == 1_000_000)

        // A picture that decodes, but is over: 600 by 600 pixels that don't compress come to about 1.4 MB.
        let big = pngData(side: 600, noisy: true)
        #expect(big.count > ImageImport.maximumBytes)
        let picture = try choose(big, as: "big.png")
        #expect(throws: ImageImportError.tooLarge) { try ImageImport.copy(picture, into: destination) }

        // The size is looked at before the bytes are: a file that couldn't be decoded either is still `tooLarge`.
        let blob = try choose(Data(repeating: 0, count: ImageImport.maximumBytes + 1), as: "blob.png")
        #expect(throws: ImageImportError.tooLarge) { try ImageImport.copy(blob, into: destination) }

        // Nothing was copied.
        #expect(copies().isEmpty)
    }

    @Test func theSizeIsCheckedBeforeAnythingIsDecoded() throws {
        // A PNG whose header claims 100,000 pixels across but whose data is that of a 1-pixel picture: it can't be decoded, so were it
        // decoded first it would be `undecodable`; it is `tooLarge` only if the header is looked at first.
        var bytes = [UInt8](pngData(side: 1))
        func put(_ value: UInt32, at offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(24 - 8 * index)) }
        }
        // The signature is 8 bytes, the chunk's length and name 8 more: the header's width and height follow, then a 4-byte checksum.
        #expect(Array(bytes[12..<16]) == Array("IHDR".utf8))
        put(100_000, at: 16)
        put(100_000, at: 20)
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes[12..<29] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        put(~crc, at: 29)
        let url = try choose(Data(bytes), as: "bomb.png")
        #expect(throws: ImageImportError.tooLarge) { try ImageImport.copy(url, into: destination, log: { _ in }) }
        #expect(copies().isEmpty)
    }

    // MARK: What can't be used

    @Test func refusesUndecodable() throws {
        let png = pngData(side: 40)
        let notPictures: [(String, Data)] = [
            ("text.png", Data("This is not a picture.".utf8)),
            ("empty.png", Data()),
            ("cut-short.png", png.prefix(png.count / 2)),
            ("cut-short.pdf", pdfData().prefix(40)),
            // A picture that decodes but is neither of the two kinds that are taken.
            ("photo.png", pngData(side: 40, type: .jpeg)),
        ]
        for (name, data) in notPictures {
            let url = try choose(data, as: name)
            #expect(throws: ImageImportError.undecodable, "\(name)") { try ImageImport.copy(url, into: destination) }
        }

        // A file that isn't there, and a folder.
        let missing = sources.appending(path: "missing.png", directoryHint: .notDirectory)
        #expect(throws: ImageImportError.undecodable) { try ImageImport.copy(missing, into: destination) }
        #expect(throws: ImageImportError.undecodable) { try ImageImport.copy(sources, into: destination) }

        // Nothing was copied, and the folder for the copies wasn't made for a file that was refused.
        #expect(copies().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: What is taken

    @Test func acceptsPNGAndPDF() throws {
        let png = pngData(side: 40)
        let pdf = pdfData()
        let pngName = try ImageImport.copy(try choose(png, as: "picture.png"), into: destination)
        let pdfName = try ImageImport.copy(try choose(pdf, as: "vector.pdf"), into: destination)
        #expect(pngName.hasSuffix(".png"))
        #expect(pdfName.hasSuffix(".pdf"))
        #expect(try Data(contentsOf: destination.appending(path: pngName)) == png)
        #expect(try Data(contentsOf: destination.appending(path: pdfName)) == pdf)

        // The kind is what the bytes say, not what the file is called.
        let renamed = try ImageImport.copy(try choose(pdf, as: "really-a-pdf.png"), into: destination)
        #expect(renamed.hasSuffix(".pdf"))
        let bare = try ImageImport.copy(try choose(png, as: "no-extension"), into: destination)
        #expect(bare.hasSuffix(".png"))
    }
}
