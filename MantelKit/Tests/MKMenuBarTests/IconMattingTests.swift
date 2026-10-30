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

    @Test func lightGlyphOnDarkBar() throws {
        let icon = try #require(IconMatting.matte(crop(bar: 0.12, glyph: gray(0.95))))
        let bytes = Bytes(icon.image)

        #expect(icon.barAppearance == .dark)
        #expect(icon.isMonochrome)
        let inside = bytes.pixel(36, 30)
        #expect(inside.alpha == 255)
        #expect(inside.red > 230 && inside.green > 230 && inside.blue > 230, "light on dark")
        #expect(bytes.pixel(3, 3).alpha == 0)
    }

    @Test func antialiasedEdgesKeepPartialAlpha() throws {
        let icon = try #require(IconMatting.matte(crop(bar: 0.92, glyph: gray(0.1))))
        let bytes = Bytes(icon.image)

        // The ring where the disc's edge fades into the bar is neither the glyph's nor the bar's.
        #expect(bytes.count(alphaBetween: 12, and: 243) > 20, "the edge has pixels that are partly the glyph's")
        // And a partly transparent pixel is premultiplied: its colour never exceeds its alpha.
        for index in 0..<(cropWidth * cropHeight) {
            let pixel = bytes.pixel(index % cropWidth, index / cropWidth)
            #expect(pixel.red <= pixel.alpha && pixel.green <= pixel.alpha && pixel.blue <= pixel.alpha)
        }
        // A glyph with no antialiasing has no such pixels.
        let hard = try #require(IconMatting.matte(crop(bar: 0.92, glyph: gray(0.1), antialias: false)))
        #expect(Bytes(hard.image).count(alphaBetween: 12, and: 243) == 0)
    }

    @Test func contentBoundsHugTheGlyph() throws {
        // A square with no antialiasing: pixels 20 to 49 across, rows 15 to 44.
        let image = picture(cropWidth, cropHeight, antialias: false) { context in
            context.setFillColor(gray(0.92))
            context.fill(CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight))
            context.setFillColor(gray(0.1))
            context.fill(CGRect(x: 20, y: cropHeight - 45, width: 30, height: 30))
        }
        let icon = try #require(IconMatting.matte(image))

        #expect(icon.contentBounds == CGRect(x: 20, y: 15, width: 30, height: 30))
        #expect(abs(icon.coverage - 900.0 / Double(cropWidth * cropHeight)) < 0.0001)
    }

    @Test func trimmedIsContentBoundsSize() throws {
        let icon = try #require(IconMatting.matte(crop(bar: 0.92, glyph: gray(0.1))))
        let trimmed = IconMatting.trimmed(icon)

        #expect(CGFloat(trimmed.width) == icon.contentBounds.width)
        #expect(CGFloat(trimmed.height) == icon.contentBounds.height)
        #expect(trimmed.width < cropWidth && trimmed.height < cropHeight)
        // The disc is 32 across, a pixel or two either way for its soft edge.
        #expect((32...34).contains(trimmed.width))
    }

    @Test func colouredIconIsNotMonochrome() throws {
        let image = picture(cropWidth, cropHeight) { context in
            context.setFillColor(gray(0.92))
            context.fill(CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight))
            disc(context, x: 26, colour(0.9, 0.1, 0.1))
            disc(context, x: 46, colour(0.1, 0.3, 0.9))
        }
        let icon = try #require(IconMatting.matte(image))

        #expect(!icon.isMonochrome)
        #expect(IconMatting.recolored(icon.image, isMonochrome: icon.isMonochrome, for: .dark) == nil)
    }

    @Test func aTintedBarDoesNotMakeAGrayGlyphColoured() throws {
        // A bar with a colour cast, and a gray glyph on it: the glyph is monochrome, whatever the bar's own colour.
        let image = picture(cropWidth, cropHeight) { context in
            context.setFillColor(colour(0.78, 0.84, 0.95))
            context.fill(CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight))
            disc(context, gray(0.1))
        }
        let icon = try #require(IconMatting.matte(image))
        #expect(icon.isMonochrome)
        #expect(icon.barAppearance == .light)
    }

    @Test func aColouredIconOnATintedBarIsStillColoured() throws {
        let image = picture(cropWidth, cropHeight) { context in
            context.setFillColor(colour(0.78, 0.84, 0.95))
            context.fill(CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight))
            disc(context, colour(0.9, 0.5, 0.1))
        }
        let icon = try #require(IconMatting.matte(image))
        #expect(!icon.isMonochrome)
    }

    @Test func recolorMonochromeForOtherAppearance() throws {
        let icon = try #require(IconMatting.matte(crop(bar: 0.92, glyph: gray(0.1))))
        let original = Bytes(icon.image)

        let forDark = try #require(IconMatting.recolored(icon.image, isMonochrome: icon.isMonochrome, for: .dark))
        let light = Bytes(forDark)
        let forLight = try #require(IconMatting.recolored(icon.image, isMonochrome: icon.isMonochrome, for: .light))
        let dark = Bytes(forLight)

        #expect(forDark.width == cropWidth && forDark.height == cropHeight)
        // The shape is kept: every alpha is the same. The colour is the one that shows on the bar: white for a dark bar, black for a light one.
        for index in 0..<(cropWidth * cropHeight) {
            let x = index % cropWidth, y = index / cropWidth
            #expect(light.pixel(x, y).alpha == original.pixel(x, y).alpha)
            #expect(dark.pixel(x, y).alpha == original.pixel(x, y).alpha)
        }
        let inside = light.pixel(36, 30)
        #expect(inside.alpha == 255 && inside.red == 255 && inside.green == 255 && inside.blue == 255)
        let blackInside = dark.pixel(36, 30)
        #expect(blackInside.alpha == 255 && blackInside.red == 0 && blackInside.green == 0 && blackInside.blue == 0)
        // At a soft edge the colour is premultiplied: white at half alpha is half of 255.
        let edge = (0..<(cropWidth * cropHeight)).map { light.pixel($0 % cropWidth, $0 / cropWidth) }.first { $0.alpha > 100 && $0.alpha < 160 }
        let soft = try #require(edge)
        #expect(soft.red == soft.alpha && soft.green == soft.alpha && soft.blue == soft.alpha)
    }

    @Test func recolorRefusesColoured() throws {
        let icon = try #require(IconMatting.matte(crop(bar: 0.92, glyph: gray(0.1))))
        #expect(IconMatting.recolored(icon.image, isMonochrome: false, for: .dark) == nil)
        #expect(IconMatting.recolored(icon.image, isMonochrome: false, for: .light) == nil)
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

    @Test func differentShapesWithTheSameBytesHashDifferently() throws {
        // A solid 20 by 10 and a solid 10 by 20 of one colour: inside their bounds the bytes are the same, 200 pixels of it.
        func solid(_ width: Int, _ height: Int) throws -> MattedIcon {
            let image = picture(cropWidth, cropHeight, antialias: false) { context in
                context.setFillColor(gray(0.92))
                context.fill(CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight))
                context.setFillColor(gray(0.1))
                context.fill(CGRect(x: 20, y: 20, width: width, height: height))
            }
            return try #require(IconMatting.matte(image))
        }
        let wide = try solid(20, 10)
        let tall = try solid(10, 20)

        #expect(wide.contentBounds.size == CGSize(width: 20, height: 10))
        #expect(tall.contentBounds.size == CGSize(width: 10, height: 20))
        #expect(wide.pixelHash != tall.pixelHash)
        #expect(try solid(20, 10).pixelHash == wide.pixelHash, "and the same shape is the same")
    }

    @Test func unevenBorderIsLowConfidence() throws {
        // A bar that is black on one side and white on the other: there is no one colour to take away.
        let split = picture(cropWidth, cropHeight) { context in
            context.setFillColor(gray(0.05))
            context.fill(CGRect(x: 0, y: 0, width: cropWidth / 2, height: cropHeight))
            context.setFillColor(gray(0.95))
            context.fill(CGRect(x: cropWidth / 2, y: 0, width: cropWidth / 2, height: cropHeight))
            disc(context, colour(0.9, 0.2, 0.2))
        }
        let icon = try #require(IconMatting.matte(split))
        #expect(icon.lowConfidence)

        #expect(try #require(IconMatting.matte(crop(bar: 0.92, glyph: gray(0.1)))).lowConfidence == false)
    }

    @Test func gentleGradientBehindTheGlyphIsFlat() throws {
        // A bar that is a little lighter at one end (it is a wallpaper through glass): the glyph is matted, the bar is still gone.
        let image = picture(cropWidth, cropHeight) { context in
            let gradient = CGGradient(colorsSpace: sRGB, colors: [gray(0.90), gray(0.93)] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: cropWidth, y: 0), options: [])
            disc(context, gray(0.1))
        }
        let icon = try #require(IconMatting.matte(image))
        let bytes = Bytes(icon.image)

        #expect(!icon.lowConfidence)
        #expect(icon.barAppearance == .light)
        #expect(bytes.pixel(3, 3).alpha == 0 && bytes.pixel(68, 56).alpha == 0, "both ends of the gradient are the bar's")
        #expect(bytes.pixel(36, 30).alpha == 255)
        #expect(icon.contentBounds.width >= 32 && icon.contentBounds.width <= 34)
    }

    @Test func steepGradientIsLowConfidence() throws {
        let image = picture(cropWidth, cropHeight) { context in
            let gradient = CGGradient(colorsSpace: sRGB, colors: [gray(0.55), gray(1.0)] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: cropWidth, y: 0), options: [])
            disc(context, gray(0.05))
        }
        #expect(try #require(IconMatting.matte(image)).lowConfidence)
    }

    @Test func theConstantsAreTheNamedValues() {
        #expect(IconMatting.borderSample == 2)
        #expect(IconMatting.alphaThreshold == 0.35)
    }

    @Test func pngDataIsAPNGOfTheSamePicture() throws {
        let icon = try #require(IconMatting.matte(crop(bar: 0.92, glyph: gray(0.1))))
        let data = try #require(IconMatting.pngData(IconMatting.trimmed(icon)))

        #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "the PNG signature")
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let back = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(back.width == IconMatting.trimmed(icon).width && back.height == IconMatting.trimmed(icon).height)
    }
}
