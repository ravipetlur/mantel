import CoreGraphics
import Foundation
import ImageIO
import MKCore
import Testing

@testable import MKMenuBar

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// A picture drawn in memory, `width` by `height` pixels: `draw` paints on a context whose origin is at the bottom-left, as CoreGraphics
/// has it. (Nothing here reads a file or the screen.)
private func picture(_ width: Int, _ height: Int, antialias: Bool = true, _ draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setShouldAntialias(antialias)
    draw(context)
    return context.makeImage()!
}

private func gray(_ level: CGFloat) -> CGColor { CGColor(colorSpace: sRGB, components: [level, level, level, 1])! }
private func colour(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor { CGColor(colorSpace: sRGB, components: [red, green, blue, 1])! }

/// A picture's pixels, premultiplied RGBA, top row first.
private struct Bytes {
    let width: Int
    let height: Int
    let data: [UInt8]

    init(_ image: CGImage) {
        let columns = image.width, rows = image.height
        var data = [UInt8](repeating: 0, count: columns * rows * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4, space: sRGB,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        }
        self.width = columns
        self.height = rows
        self.data = data
    }

    func pixel(_ x: Int, _ y: Int) -> (red: Int, green: Int, blue: Int, alpha: Int) {
        let base = (y * width + x) * 4
        return (Int(data[base]), Int(data[base + 1]), Int(data[base + 2]), Int(data[base + 3]))
    }

    /// How many pixels have an alpha between these (exclusive), of 255.
    func count(alphaBetween low: Int, and high: Int) -> Int {
        (0..<(width * height)).filter { low < Int(data[$0 * 4 + 3]) && Int(data[$0 * 4 + 3]) < high }.count
    }
}

/// The size of every crop below: 36 by 30 points of a bar at 2x.
private let cropWidth = 72
private let cropHeight = 60

/// A glyph: a filled disc `radius` pixels across, centred at `x` pixels from the left and `y` pixels from the top.
private func disc(_ context: CGContext, x: CGFloat = 36, y: CGFloat = 30, radius: CGFloat = 16, _ colour: CGColor) {
    context.setFillColor(colour)
    context.fillEllipse(in: CGRect(x: x - radius, y: CGFloat(cropHeight) - y - radius, width: radius * 2, height: radius * 2))
}

private func crop(bar: CGFloat, glyph: CGColor, antialias: Bool = true) -> CGImage {
    picture(cropWidth, cropHeight, antialias: antialias) { context in
        context.setFillColor(gray(bar))
        context.fill(CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight))
        disc(context, glyph)
    }
}

@Suite("Icon matting", .timeLimit(.minutes(1)))
struct IconMattingTests {
    @Test func darkGlyphOnLightBarMattesToDarkWithAlpha() throws {
        let icon = try #require(IconMatting.matte(crop(bar: 0.92, glyph: gray(0.1))))
        let bytes = Bytes(icon.image)

        #expect(icon.barAppearance == .light)
        #expect(icon.isMonochrome)
        #expect(!icon.lowConfidence)
        #expect(icon.image.width == cropWidth && icon.image.height == cropHeight, "the crop's own size")

        let inside = bytes.pixel(36, 30)
        #expect(inside.alpha == 255, "the glyph is opaque")
        #expect(inside.red < 40 && inside.green < 40 && inside.blue < 40, "and dark: the bar is out of it")
        let corner = bytes.pixel(3, 3)
        #expect(corner.alpha == 0 && corner.red == 0 && corner.green == 0 && corner.blue == 0, "the bar is transparent")
        let far = bytes.pixel(70, 58)
        #expect(far.alpha == 0)
    }

    @Test func emptyCropIsNil() {
        // Nothing in it that isn't the bar.
        let flat = picture(cropWidth, cropHeight) { context in
            context.setFillColor(gray(0.92))
            context.fill(CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight))
        }
        #expect(IconMatting.matte(flat) == nil)
        // A crop no bigger than its own border has no inside to hold anything.
        let sliver = picture(3, 3) { context in
            context.setFillColor(gray(0.92))
            context.fill(CGRect(x: 0, y: 0, width: 3, height: 3))
        }
        #expect(IconMatting.matte(sliver) == nil)
        // A glyph as faint as the bar's own noise is not one.
        let faint = crop(bar: 0.92, glyph: gray(0.915))
        #expect(IconMatting.matte(faint) == nil)
    }

    @Test func hashIsStableForSamePixels() throws {
        let first = try #require(IconMatting.matte(crop(bar: 0.92, glyph: gray(0.1))))
        let second = try #require(IconMatting.matte(crop(bar: 0.92, glyph: gray(0.1))))
        #expect(first.pixelHash == second.pixelHash)
        #expect(first.pixelHash.count == 64, "SHA-256, in hex")
        #expect(first.pixelHash.allSatisfy { $0.isHexDigit && !$0.isUppercase })

        // The pixels inside the bounds are what is hashed, so the glyph drawn a few pixels over is the same picture.
        let moved = picture(cropWidth, cropHeight) { context in
            context.setFillColor(gray(0.92))
            context.fill(CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight))
            disc(context, x: 39, y: 28, gray(0.1))
        }
        #expect(try #require(IconMatting.matte(moved)).pixelHash == first.pixelHash)

        // Another picture, another hash.
        let other = try #require(IconMatting.matte(crop(bar: 0.92, glyph: gray(0.4))))
        #expect(other.pixelHash != first.pixelHash)
        let smaller = try #require(IconMatting.matte(picture(cropWidth, cropHeight) { context in
            context.setFillColor(gray(0.92))
            context.fill(CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight))
            disc(context, radius: 12, gray(0.1))
        }))
        #expect(smaller.pixelHash != first.pixelHash)
    }

}
