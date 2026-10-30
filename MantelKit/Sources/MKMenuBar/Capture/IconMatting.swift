import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import MKCore
import UniformTypeIdentifiers

/// An icon lifted off the menu bar it was captured on: what is left of a crop of the bar when the bar is taken away.
public struct MattedIcon: Sendable {
    /// The icon, premultiplied RGBA, the size of the crop in pixels. Where the bar showed through it is transparent.
    public let image: CGImage
    /// Pixels, from the image's top-left corner: the smallest rectangle that holds every pixel with alpha above 0.1.
    public let contentBounds: CGRect
    /// Whether the bar the icon was on was light or dark, from the background's luminance.
    public let barAppearance: BarAppearance
    /// The share of the crop's pixels that have alpha above 0.1.
    public let coverage: Double
    /// Every opaque pixel has a saturation under 0.15: the icon is a glyph of one colour (a template), which can be drawn in another.
    public let isMonochrome: Bool
    /// SHA-256 of the size of `contentBounds` and the matted pixels inside it, in hex: the same picture gives the same hash, and a change
    /// shows.
    public let pixelHash: String
    /// The crop's border wasn't one colour (it varied by more than 0.2), so the background is a guess, and so is what was taken from it.
    public let lowConfidence: Bool

    public init(image: CGImage, contentBounds: CGRect, barAppearance: BarAppearance, coverage: Double, isMonochrome: Bool, pixelHash: String,
                lowConfidence: Bool) {
        self.image = image
        self.contentBounds = contentBounds
        self.barAppearance = barAppearance
        self.coverage = coverage
        self.isMonochrome = isMonochrome
        self.pixelHash = pixelHash
        self.lowConfidence = lowConfidence
    }
}

/// Takes the menu bar out from behind a picture of an icon.
///
/// A capture of the bar's strip has the icon on whatever the bar looks like at that place: a flat colour, or the wallpaper through it. The
/// background is taken to be the colour the crop's border has (its median), and each pixel's alpha is how far its colour is from that,
/// over `alphaThreshold`: a pixel as far as that or further is the icon's, and one that is no further than a tenth of it is the bar's.
/// The icon's own colour is what the pixel's colour was before the bar showed through (`colour = alpha × icon + (1 − alpha) × bar`).
public enum IconMatting {
    /// How many pixels at each edge of the crop are the border the background is taken from.
    public static let borderSample = 2
    /// The colour distance (0 to √3, across the unit cube of red, green and blue) from the background at which a pixel is fully the icon's.
    public static let alphaThreshold: Double = 0.35
    /// A pixel closer to the background than this share of `alphaThreshold` is the background, and fully transparent.
    public static let transparentShare = 0.1
    /// A pixel with more alpha than this is part of the icon: it counts for the bounds, the coverage and the hash.
    public static let contentAlpha = 0.1
    /// A pixel at least this opaque is judged for colour.
    public static let opaqueAlpha = 0.99
    /// Below this saturation (0 to 1) an opaque pixel is gray: how far its colour is from what a gray glyph could show on this bar, over how
    /// bright it is. A pixel darker than `grayBelowBrightness` has no colour to speak of.
    public static let monochromeSaturation = 0.15
    public static let grayBelowBrightness = 0.1
    /// A bar whose colour is this far from gray (colour distance) has a tint, which the edges of a gray glyph take on.
    public static let tintedBar = 0.02
    /// A border whose pixels are further than this from the background (colour distance) isn't one colour.
    public static let borderSpread = 0.2
    /// A background brighter than this (0 to 1) is a light bar.
    public static let lightLuminance = 0.5

    // MARK: Matting

    /// The icon in `crop`, or nil for a crop with no pixels, or one with nothing in it that isn't the bar.
    public static func matte(_ crop: CGImage) -> MattedIcon? {
        let width = crop.width, height = crop.height
        guard width > 0, height > 0, var pixels = Pixels.read(crop) else { return nil }

        let border = borderPixels(width: width, height: height)
        guard !border.isEmpty else { return nil }
        let background = median(of: border, in: pixels)
        let spread = border.map { distance(pixels.colour(at: $0), background) }.max() ?? 0

        var content = Bounds()
        var contentCount = 0
        var isMonochrome = true
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let colour = pixels.colour(at: index)
                let away = distance(colour, background)
                let alpha = alpha(forDistance: away)
                pixels.store(matted(colour, alpha: alpha, background: background), at: index)
                guard alpha > contentAlpha else { continue }
                content.add(x: x, y: y)
                contentCount += 1
                if alpha >= opaqueAlpha, isColoured(colour, background: background) { isMonochrome = false }
            }
        }
        guard let bounds = content.rect, let image = pixels.image() else { return nil }

        let luminance = 0.2126 * background.red + 0.7152 * background.green + 0.0722 * background.blue
        return MattedIcon(image: image, contentBounds: bounds, barAppearance: luminance > lightLuminance ? .light : .dark,
                          coverage: Double(contentCount) / Double(width * height), isMonochrome: isMonochrome,
                          pixelHash: hash(of: pixels, inside: bounds), lowConfidence: spread > borderSpread)
    }

    /// The icon cut to its content bounds: what is kept, so that an icon fills the room it is given.
    public static func trimmed(_ icon: MattedIcon) -> CGImage {
        icon.image.cropping(to: icon.contentBounds) ?? icon.image
    }

    /// A glyph of one colour drawn in the colour that shows on a bar of `appearance` (black on a light bar, white on a dark one); its alpha,
    /// and so its shape, is kept. Nil for an icon that isn't of one colour: it is used as it was captured.
    public static func recolored(_ image: CGImage, isMonochrome: Bool, for appearance: BarAppearance) -> CGImage? {
        guard isMonochrome, var pixels = Pixels.read(image) else { return nil }
        let level: Double = appearance == .light ? 0 : 1
        for index in 0..<(pixels.width * pixels.height) {
            let alpha = pixels.alpha(at: index)
            // Premultiplied: the colour is the level times the alpha.
            pixels.storePremultiplied(red: level * alpha, green: level * alpha, blue: level * alpha, alpha: alpha, at: index)
        }
        return pixels.image()
    }

    /// The picture as a PNG.
    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: Colour

    struct Colour {
        var red: Double
        var green: Double
        var blue: Double
    }

    /// How far apart two colours are: Euclidean, in the unit cube (0 to √3).
    static func distance(_ one: Colour, _ other: Colour) -> Double {
        let r = one.red - other.red, g = one.green - other.green, b = one.blue - other.blue
        return (r * r + g * g + b * b).squareRoot()
    }

    /// 0 for a pixel the background's own, 1 for a pixel the icon's, and between for the edges.
    static func alpha(forDistance distance: Double) -> Double {
        guard distance >= alphaThreshold * transparentShare else { return 0 }
        return min(distance / alphaThreshold, 1)
    }

    /// The colour of the pixel with the background taken away, premultiplied: `colour − (1 − alpha) × background`, which is
    /// `alpha × icon`. Held to what a premultiplied colour can be.
    static func matted(_ colour: Colour, alpha: Double, background: Colour) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        guard alpha > 0 else { return (0, 0, 0, 0) }
        func channel(_ value: Double, _ behind: Double) -> Double { min(max(value - (1 - alpha) * behind, 0), alpha) }
        return (channel(colour.red, background.red), channel(colour.green, background.green), channel(colour.blue, background.blue), alpha)
    }

    /// Whether an opaque pixel has a colour of its own: a saturation of `monochromeSaturation` or more.
    ///
    /// A gray glyph on a bar is a mix of gray and the bar's colour (`colour = alpha × gray + (1 − alpha) × bar`), so the pixels at its soft
    /// edges are as tinted as the bar is, and that is no colour of the glyph's. The saturation is how far the pixel is from every such mix
    /// (between none of the bar's tint and all of it), over how bright the pixel is. With a bar that is gray there is no tint: it is how far
    /// the pixel is from gray.
    private static func isColoured(_ colour: Colour, background: Colour) -> Bool {
        let brightness = max(colour.red, colour.green, colour.blue)
        guard brightness > grayBelowBrightness else { return false }

        // The gray axis (unit), and the part of the bar's colour that isn't along it.
        let axis = 1 / 3.0.squareRoot()
        let backgroundAlong = (background.red + background.green + background.blue) * axis
        let tint = Colour(red: background.red - backgroundAlong * axis, green: background.green - backgroundAlong * axis,
                          blue: background.blue - backgroundAlong * axis)
        let tintLength = distance(tint, Colour(red: 0, green: 0, blue: 0))
        let grayPart = (colour.red + colour.green + colour.blue) * axis
        var off = Colour(red: colour.red - grayPart * axis, green: colour.green - grayPart * axis, blue: colour.blue - grayPart * axis)
        if tintLength >= tintedBar {
            // Take out what the bar's tint explains: some of it, from none to all (a gray glyph never has more of the bar's tint than the bar
            // has, and never the opposite tint).
            let unit = Colour(red: tint.red / tintLength, green: tint.green / tintLength, blue: tint.blue / tintLength)
            let along = off.red * unit.red + off.green * unit.green + off.blue * unit.blue
            let explained = min(max(along, 0), tintLength)
            off = Colour(red: off.red - explained * unit.red, green: off.green - explained * unit.green, blue: off.blue - explained * unit.blue)
        }
        return distance(off, Colour(red: 0, green: 0, blue: 0)) / brightness >= monochromeSaturation
    }

    // MARK: Pixels

    /// The pixels of the border: `borderSample` wide at every edge.
    private static func borderPixels(width: Int, height: Int) -> [Int] {
        var border: [Int] = []
        for y in 0..<height {
            for x in 0..<width where x < borderSample || y < borderSample || x >= width - borderSample || y >= height - borderSample {
                border.append(y * width + x)
            }
        }
        return border
    }

    /// The colour that is the middle value of each channel over these pixels.
    private static func median(of indices: [Int], in pixels: Pixels) -> Colour {
        var counts = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        for index in indices {
            let straight = pixels.straightBytes(at: index)
            counts[0][Int(straight.red)] += 1
            counts[1][Int(straight.green)] += 1
            counts[2][Int(straight.blue)] += 1
        }
        func middle(_ histogram: [Int]) -> Double {
            var seen = 0
            for (value, count) in histogram.enumerated() {
                seen += count
                if seen * 2 >= indices.count { return Double(value) / 255 }
            }
            return 1
        }
        return Colour(red: middle(counts[0]), green: middle(counts[1]), blue: middle(counts[2]))
    }

    /// SHA-256 of the width and height of `bounds` (each as four bytes, big end first), then the premultiplied bytes of the pixels inside
    /// it, row by row: two shapes whose pixels make the same bytes (a solid 20 by 10 and a solid 10 by 20) are not one picture.
    private static func hash(of pixels: Pixels, inside bounds: CGRect) -> String {
        var hasher = SHA256()
        let minX = Int(bounds.minX), maxX = Int(bounds.maxX), minY = Int(bounds.minY), maxY = Int(bounds.maxY)
        for side in [maxX - minX, maxY - minY] {
            hasher.update(data: Data([UInt8((side >> 24) & 0xFF), UInt8((side >> 16) & 0xFF), UInt8((side >> 8) & 0xFF), UInt8(side & 0xFF)]))
        }
        for y in minY..<maxY { hasher.update(data: pixels.rowBytes(y: y, from: minX, to: maxX)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The smallest rectangle of pixels that holds the ones that were added.
    private struct Bounds {
        private var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1

        mutating func add(x: Int, y: Int) {
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }

        var rect: CGRect? {
            maxX >= 0 ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) : nil
        }
    }

    /// A picture's pixels as 8-bit premultiplied RGBA in sRGB, top row first, with no padding between rows.
    private struct Pixels {
        let width: Int
        let height: Int
        private var bytes: [UInt8]

        private static let colourSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        /// The picture drawn into a bitmap of that kind; nil if one can't be made.
        static func read(_ image: CGImage) -> Pixels? {
            let width = image.width, height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: colourSpace, bitmapInfo: bitmapInfo) else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            return drawn ? Pixels(width: width, height: height, bytes: bytes) : nil
        }

        private init(width: Int, height: Int, bytes: [UInt8]) {
            self.width = width
            self.height = height
            self.bytes = bytes
        }

        /// The picture these pixels make.
        func image() -> CGImage? {
            let data = Data(bytes)
            guard let provider = CGDataProvider(data: data as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: Self.colourSpace,
                           bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo), provider: provider, decode: nil, shouldInterpolate: false,
                           intent: .defaultIntent)
        }

        /// The red, green and blue bytes of a pixel, with the alpha taken out of them (a capture is opaque, and has none to take).
        func straightBytes(at index: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
            let base = index * 4
            let alpha = Int(bytes[base + 3])
            if alpha == 0 { return (0, 0, 0) }
            if alpha == 255 { return (bytes[base], bytes[base + 1], bytes[base + 2]) }
            func straight(_ offset: Int) -> UInt8 { UInt8(min((Int(bytes[base + offset]) * 255 + alpha / 2) / alpha, 255)) }
            return (straight(0), straight(1), straight(2))
        }

        func colour(at index: Int) -> Colour {
            let straight = straightBytes(at: index)
            return Colour(red: Double(straight.red) / 255, green: Double(straight.green) / 255, blue: Double(straight.blue) / 255)
        }

        func alpha(at index: Int) -> Double {
            Double(bytes[index * 4 + 3]) / 255
        }

        /// Stores a premultiplied colour, each channel 0 to 1.
        mutating func store(_ pixel: (red: Double, green: Double, blue: Double, alpha: Double), at index: Int) {
            storePremultiplied(red: pixel.red, green: pixel.green, blue: pixel.blue, alpha: pixel.alpha, at: index)
        }

        mutating func storePremultiplied(red: Double, green: Double, blue: Double, alpha: Double, at index: Int) {
            func byte(_ value: Double) -> UInt8 { UInt8(min(max((value * 255).rounded(), 0), 255)) }
            let base = index * 4
            let a = byte(alpha)
            bytes[base] = min(byte(red), a)
            bytes[base + 1] = min(byte(green), a)
            bytes[base + 2] = min(byte(blue), a)
            bytes[base + 3] = a
        }

        /// The bytes of row `y` from column `from` up to (not including) `to`.
        func rowBytes(y: Int, from: Int, to: Int) -> Data {
            Data(bytes[(y * width + from) * 4..<(y * width + to) * 4])
        }
    }
}
