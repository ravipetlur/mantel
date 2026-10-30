import CoreGraphics
import Foundation
import ImageIO
import MKCore
import UniformTypeIdentifiers

/// Why a picture the person chose can't be used. Both say the same thing, since what the person can do about either is choose another.
public enum ImageImportError: Error, Equatable, LocalizedError {
    /// The file is bigger than `ImageImport.maximumBytes`, or a PNG with more than `ImageImport.maximumPixelsPerSide` pixels on a side.
    case tooLarge
    /// The file can't be read, isn't a PNG or a PDF, or is one that can't be decoded.
    case undecodable

    public var errorDescription: String? {
        "Mantel couldn't use that image. Choose a PNG or PDF under 1 MB."
    }
}

/// Takes in a picture the person chose (for a dot or for a group's icon): checks it, and keeps a copy of its own in Mantel's folder, so
/// that the picture goes on working when the file it came from is moved or deleted.
public enum ImageImport {
    /// The biggest file that is taken in, in bytes.
    public static let maximumBytes = 1_000_000

    /// The most pixels a PNG may have along either side. A small file can still decode to something huge; this keeps it to about 64 MB.
    public static let maximumPixelsPerSide = 4096

    /// How many names are tried before giving up on finding one that is free. (A name is 8 hexadecimal characters, so a second try is
    /// rare, and a tenth is not to be seen.)
    private static let nameAttempts = 16

    /// Checks a PNG or PDF, copies it into `folder` under a new name, and returns that name: 8 lowercase hexadecimal characters and the
    /// kind's extension (`png` or `pdf`), whatever the source was called. The folder is made when it isn't there.
    ///
    /// The kind is what the file's own bytes say. A file that is too big is refused before it is read; one that can't be read, that is
    /// neither a PNG nor a PDF, or that is one of them but can't be decoded (a PNG cut short, a PDF with no page or one that needs a
    /// password) is `undecodable`. So is a file that couldn't be copied: the person's remedy is the same.
    ///
    /// A PNG with more than `maximumPixelsPerSide` pixels along a side is `tooLarge`. When the copy can't be kept, `log` is told why
    /// (the cause only, no names or paths).
    public static func copy(_ source: URL, into folder: URL,
                            log: (String) -> Void = { Log.warning("image-import", $0) }) throws(ImageImportError) -> String {
        let data = try read(source)
        guard let kind = try Kind(of: data) else { throw .undecodable }
        return try store(data, as: kind, in: folder, log: log)
    }

    // MARK: Reading

    private static func read(_ source: URL) throws(ImageImportError) -> Data {
        let file = source.resolvingSymlinksInPath()
        let values: URLResourceValues
        do {
            values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw .undecodable
        }
        guard values.isRegularFile == true, let size = values.fileSize else { throw .undecodable }
        guard size <= maximumBytes else { throw .tooLarge }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw .undecodable
        }
        // The file may have grown between the two looks.
        guard data.count <= maximumBytes else { throw .tooLarge }
        return data
    }

    // MARK: Kinds

    private enum Kind: Equatable {
        case png, pdf

        var fileExtension: String {
            switch self {
            case .png: "png"
            case .pdf: "pdf"
            }
        }

        /// The kind the bytes are, when they are a PNG or a PDF that decodes; nil for anything else.
        init?(of data: Data) throws(ImageImportError) {
            if try Self.decodesAsPNG(data) {
                self = .png
            } else if Self.decodesAsPDF(data) {
                self = .pdf
            } else {
                return nil
            }
        }

        /// The larger of a PNG's width and height in pixels, read from its header chunk (the 8-byte signature, then a chunk whose 4-byte
        /// length and 4-byte name come before the width and the height). Nothing is decoded. Zero when the bytes don't start like a PNG.
        static func pixelsPerSide(ofPNG data: Data) -> Int {
            let bytes = [UInt8](data.prefix(24))
            guard bytes.count == 24, Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
                  Array(bytes[12..<16]) == Array("IHDR".utf8) else { return 0 }
            func value(at offset: Int) -> Int { bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) } }
            return max(value(at: 16), value(at: 20))
        }

        /// Whether the bytes are a PNG that decodes. A PNG whose header says it is over `maximumPixelsPerSide` is refused (`tooLarge`)
        /// before anything is decoded, so a small file that would expand hugely is never expanded.
        private static func decodesAsPNG(_ data: Data) throws(ImageImportError) -> Bool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetType(source) as String? == UTType.png.identifier else { return false }
            if pixelsPerSide(ofPNG: data) > maximumPixelsPerSide { throw .tooLarge }
            guard CGImageSourceGetStatus(source) == .statusComplete,
                  CGImageSourceGetCount(source) > 0,
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return false }
            return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        }

        private static func decodesAsPDF(_ data: Data) -> Bool {
            guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
                  document.isUnlocked, document.numberOfPages > 0 else { return false }
            return document.page(at: 1) != nil
        }
    }

    // MARK: Keeping

    private static func store(_ data: Data, as kind: Kind, in folder: URL, log: (String) -> Void) throws(ImageImportError) -> String {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            log("the picture couldn't be kept: its folder couldn't be made")
            throw .undecodable
        }
        for _ in 0..<nameAttempts {
            let name = String(format: "%08x", UInt32.random(in: .min ... .max)) + "." + kind.fileExtension
            let destination = folder.appending(path: name, directoryHint: .notDirectory)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                log("the picture couldn't be kept: the copy couldn't be written")
                throw .undecodable
            }
            return name
        }
        log("the picture couldn't be kept: no free name after \(nameAttempts) tries")
        throw .undecodable
    }
}
