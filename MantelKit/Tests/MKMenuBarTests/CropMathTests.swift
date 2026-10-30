import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

/// A bar with this rectangle, on a display that doesn't matter to what is measured.
private func bar(_ rect: CGRect, notch: CGRect? = nil) -> MenuBarGeometry {
    MenuBarGeometry(displayUUID: "7B0E1E64-5D0F-4F5B-9A53-1C2D3E4F5A6B", rect: rect, notch: notch)
}

@Suite("Crop math", .timeLimit(.minutes(1)))
struct CropMathTests {
    struct Case: Sendable {
        let name: String
        let strip: CGRect
        let item: CGRect
        let scale: CGFloat
        let crop: CGRect?
    }

    private static let wide = CGRect(x: 0, y: 0, width: 3360, height: 31)
    private static let short = CGRect(x: 0, y: 0, width: 100, height: 31)

    @Test(arguments: [
        Case(name: "an item at the strip's left edge on a 2x scale", strip: wide, item: CGRect(x: 0, y: 0, width: 40, height: 31), scale: 2,
             crop: CGRect(x: 0, y: 0, width: 80, height: 62)),
        Case(name: "an item in the middle is measured from the strip's origin", strip: wide, item: CGRect(x: 3300, y: 2, width: 50, height: 27), scale: 2,
             crop: CGRect(x: 6600, y: 4, width: 100, height: 54)),
        // The side display's CoreGraphics bounds are (-1800, -491, 1800, 3200); a 24-point strip along its top.
        Case(name: "the strip of a side display left of the main one has negative coordinates",
             strip: CGRect(x: -1800, y: -491, width: 1800, height: 24), item: CGRect(x: -60, y: -491, width: 50, height: 24), scale: 2,
             crop: CGRect(x: 3480, y: 0, width: 100, height: 48)),
        Case(name: "below the strip", strip: wide, item: CGRect(x: 0, y: 100, width: 40, height: 31), scale: 2, crop: nil),
        Case(name: "right of the strip", strip: wide, item: CGRect(x: 4000, y: 0, width: 40, height: 31), scale: 2, crop: nil),
        Case(name: "left of the strip", strip: wide, item: CGRect(x: -100, y: 0, width: 40, height: 31), scale: 2, crop: nil),
        Case(name: "touching the strip's edge only", strip: wide, item: CGRect(x: 3360, y: 0, width: 40, height: 31), scale: 2, crop: nil),
        Case(name: "partly outside is cut at the edge", strip: short, item: CGRect(x: 80, y: -5, width: 40, height: 20), scale: 2,
             crop: CGRect(x: 160, y: 0, width: 40, height: 30)),
        // The near edges, 20.5 and 2.5 pixels, are rounded down to 20 and 2; the far ones, 61.5 and 23.5, up to 62 and 24.
        Case(name: "a fractional item is rounded out to whole pixels", strip: short, item: CGRect(x: 10.25, y: 1.25, width: 20.5, height: 10.5), scale: 2,
             crop: CGRect(x: 20, y: 2, width: 42, height: 22)),
        Case(name: "no area", strip: short, item: CGRect(x: 5, y: 5, width: 0, height: 10), scale: 2, crop: nil),
        Case(name: "no scale", strip: short, item: CGRect(x: 5, y: 5, width: 10, height: 10), scale: 0, crop: nil),
        Case(name: "no strip", strip: .zero, item: CGRect(x: 5, y: 5, width: 10, height: 10), scale: 2, crop: nil),
        Case(name: "a scale of one is points", strip: CGRect(x: 10, y: 20, width: 100, height: 31), item: CGRect(x: 15, y: 20, width: 30, height: 31),
             scale: 1, crop: CGRect(x: 5, y: 0, width: 30, height: 31)),
        // With the lid open the laptop's bar is at CoreGraphics (3360, 773): a crop of an item in it, by global frames.
        Case(name: "an item on the laptop bar is cropped from the bar's place", strip: CGRect(x: 3360, y: 773, width: 1728, height: 33),
             item: CGRect(x: 4318, y: 774, width: 24, height: 30), scale: 2, crop: CGRect(x: 1916, y: 2, width: 48, height: 60)),
    ])
    func pixelRect(_ example: Case) {
        #expect(CropMath.pixelRect(bar: bar(example.strip), item: example.item, scale: example.scale) == example.crop, "\(example.name)")
    }
}

@Suite("Strip capture", .timeLimit(.minutes(1)))
struct StripCaptureTests {
    // MARK: Cropping an image

    /// An image `width` × `height` pixels, red in its left half and blue in its right half.
    private func twoColorImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0, 0, 1, 1])!)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return try #require(context.makeImage())
    }

    private struct RGB: Equatable {
        var red: UInt8, green: UInt8, blue: UInt8
    }

    private func firstPixel(of image: CGImage) throws -> RGB {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).bindMemory(to: UInt8.self, capacity: 4)
        return RGB(red: data[0], green: data[1], blue: data[2])
    }

    @Test func cropTakesTheItemsPixels() throws {
        // A 200 × 62 pixel capture of a 100 × 31 point strip at 2x.
        let image = try twoColorImage(width: 200, height: 62)
        let strip = CGRect(x: 0, y: 0, width: 100, height: 31)

        let left = try #require(StripCapture.crop(image, bar: bar(strip), item: CGRect(x: 0, y: 0, width: 20, height: 31), scale: 2))
        #expect(left.width == 40 && left.height == 62)
        let leftPixel = try firstPixel(of: left)
        #expect(leftPixel == RGB(red: 255, green: 0, blue: 0))

        let right = try #require(StripCapture.crop(image, bar: bar(strip), item: CGRect(x: 60, y: 5, width: 30, height: 20), scale: 2))
        #expect(right.width == 60 && right.height == 40)
        let rightPixel = try firstPixel(of: right)
        #expect(rightPixel == RGB(red: 0, green: 0, blue: 255))
    }

    @Test func cropOfAnItemOutsideTheStripIsNil() throws {
        let image = try twoColorImage(width: 200, height: 62)
        let strip = CGRect(x: 0, y: 0, width: 100, height: 31)
        #expect(StripCapture.crop(image, bar: bar(strip), item: CGRect(x: 500, y: 0, width: 10, height: 10), scale: 2) == nil)
    }

    // MARK: Where the strip is

    struct Geometry: Sendable {
        let name: String
        let bar: CGRect
        let notch: CGRect?
        let display: DisplayInfo
        let layout: DisplayLayout
        let strip: CGRect
        /// The capture's source rectangle, in the display's own points, when the case says it.
        let sourceRect: CGRect?
        let pixelSize: CGSize?
    }

    @Test(arguments: [
        // The bar is MenuBarAgent's window, 30 points, and not what the display's visible frame leaves (31).
        Geometry(name: "the main display's strip is the bar's window at the top of its frame", bar: CGRect(x: 0, y: 0, width: 3360, height: 30), notch: nil,
                 display: DisplayFixtures.deskMain, layout: .desk, strip: CGRect(x: 0, y: 0, width: 3360, height: 30),
                 sourceRect: CGRect(x: 0, y: 0, width: 3360, height: 30), pixelSize: CGSize(width: 6720, height: 60)),
        // The side display's bar: its top is at CoreGraphics y = -491, and it starts at x = -1800.
        Geometry(name: "a display left of the main one gives its strip in global and local points",
                 bar: CGRect(x: -1800, y: -491, width: 1800, height: 30), notch: nil, display: DisplayFixtures.deskPortrait, layout: .desk,
                 strip: CGRect(x: -1800, y: -491, width: 1800, height: 30), sourceRect: CGRect(x: 0, y: 0, width: 1800, height: 30),
                 pixelSize: CGSize(width: 3600, height: 60)),
        Geometry(name: "the notched laptop's strip is its full width and thirty-three points high",
                 bar: CGRect(x: 0, y: 0, width: 1728, height: 33), notch: CGRect(x: 771.5, y: 0, width: 185, height: 32),
                 display: DisplayFixtures.laptopAlone, layout: .laptop, strip: CGRect(x: 0, y: 0, width: 1728, height: 33), sourceRect: nil,
                 pixelSize: CGSize(width: 3456, height: 66)),
        // With the lid open the laptop's bar is at CoreGraphics (3360, 773); the capture's source rectangle is in the display's own points.
        Geometry(name: "the laptop beside the desk captures from its own top left corner", bar: CGRect(x: 3360, y: 773, width: 1728, height: 33), notch: nil,
                 display: DisplayFixtures.laptopRightOfDesk, layout: .deskWithLaptopOpen, strip: CGRect(x: 3360, y: 773, width: 1728, height: 33),
                 sourceRect: CGRect(x: 0, y: 0, width: 1728, height: 33), pixelSize: nil),
    ])
    func theStripOfADisplay(_ example: Geometry) throws {
        let geometry = try StripGeometry.of(bar(example.bar, notch: example.notch), display: example.display, layout: example.layout)
        #expect(geometry.strip == example.strip, "\(example.name)")
        if let sourceRect = example.sourceRect { #expect(geometry.sourceRect == sourceRect, "\(example.name)") }
        if let pixelSize = example.pixelSize { #expect(geometry.pixelSize == pixelSize, "\(example.name)") }
    }

    @Test func aBarWithNoRectangleHasNoStrip() {
        #expect(throws: StripCaptureError.noMenuBar) {
            try StripGeometry.of(bar(.zero), display: DisplayFixtures.deskPortrait, layout: .desk)
        }
    }
}
