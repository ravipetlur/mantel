import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

@Suite("Crop math", .timeLimit(.minutes(1)))
struct CropMathTests {
    @Test func anItemAtTheStripsLeftEdgeOnA2xScale() {
        let strip = CGRect(x: 0, y: 0, width: 3360, height: 31)
        let item = CGRect(x: 0, y: 0, width: 40, height: 31)
        #expect(CropMath.pixelRect(strip: strip, item: item, scale: 2) == CGRect(x: 0, y: 0, width: 80, height: 62))
    }

    @Test func anItemInTheMiddleOfTheStripIsMeasuredFromTheStripsOrigin() {
        let strip = CGRect(x: 0, y: 0, width: 3360, height: 31)
        let item = CGRect(x: 3300, y: 2, width: 50, height: 27)
        #expect(CropMath.pixelRect(strip: strip, item: item, scale: 2) == CGRect(x: 6600, y: 4, width: 100, height: 54))
    }

    @Test func theStripOfTheLGLeftOfTheMainDisplayHasNegativeCoordinates() {
        // The LG's CoreGraphics bounds are (-1800, -491, 1800, 3200); a 24-point strip along its top.
        let strip = CGRect(x: -1800, y: -491, width: 1800, height: 24)
        let item = CGRect(x: -60, y: -491, width: 50, height: 24)
        #expect(CropMath.pixelRect(strip: strip, item: item, scale: 2) == CGRect(x: 3480, y: 0, width: 100, height: 48))
    }

    @Test func anItemOutsideTheStripHasNoCrop() {
        let strip = CGRect(x: 0, y: 0, width: 3360, height: 31)
        #expect(CropMath.pixelRect(strip: strip, item: CGRect(x: 0, y: 100, width: 40, height: 31), scale: 2) == nil, "below it")
        #expect(CropMath.pixelRect(strip: strip, item: CGRect(x: 4000, y: 0, width: 40, height: 31), scale: 2) == nil, "right of it")
        #expect(CropMath.pixelRect(strip: strip, item: CGRect(x: -100, y: 0, width: 40, height: 31), scale: 2) == nil, "left of it")
        #expect(CropMath.pixelRect(strip: strip, item: CGRect(x: 3360, y: 0, width: 40, height: 31), scale: 2) == nil, "touching its edge only")
    }

    @Test func anItemPartlyOutsideIsCutAtTheEdge() {
        let strip = CGRect(x: 0, y: 0, width: 100, height: 31)
        let item = CGRect(x: 80, y: -5, width: 40, height: 20)
        #expect(CropMath.pixelRect(strip: strip, item: item, scale: 2) == CGRect(x: 160, y: 0, width: 40, height: 30))
    }

    @Test func aFractionalItemIsRoundedOutToWholePixels() {
        let strip = CGRect(x: 0, y: 0, width: 100, height: 31)
        let item = CGRect(x: 10.25, y: 1.25, width: 20.5, height: 10.5)
        // The near edges, 20.5 and 2.5 pixels, are rounded down to 20 and 2; the far ones, 61.5 and 23.5, up to 62 and 24.
        #expect(CropMath.pixelRect(strip: strip, item: item, scale: 2) == CGRect(x: 20, y: 2, width: 42, height: 22))
    }

    @Test func noAreaOrNoScaleHasNoCrop() {
        let strip = CGRect(x: 0, y: 0, width: 100, height: 31)
        #expect(CropMath.pixelRect(strip: strip, item: CGRect(x: 5, y: 5, width: 0, height: 10), scale: 2) == nil)
        #expect(CropMath.pixelRect(strip: strip, item: CGRect(x: 5, y: 5, width: 10, height: 10), scale: 0) == nil)
        #expect(CropMath.pixelRect(strip: .zero, item: CGRect(x: 5, y: 5, width: 10, height: 10), scale: 2) == nil)
    }

    @Test func aScaleOfOneIsPoints() {
        let strip = CGRect(x: 10, y: 20, width: 100, height: 31)
        #expect(CropMath.pixelRect(strip: strip, item: CGRect(x: 15, y: 20, width: 30, height: 31), scale: 1) == CGRect(x: 5, y: 0, width: 30, height: 31))
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

        let left = try #require(StripCapture.crop(image, strip: strip, item: CGRect(x: 0, y: 0, width: 20, height: 31), scale: 2))
        #expect(left.width == 40 && left.height == 62)
        let leftPixel = try firstPixel(of: left)
        #expect(leftPixel == RGB(red: 255, green: 0, blue: 0))

        let right = try #require(StripCapture.crop(image, strip: strip, item: CGRect(x: 60, y: 5, width: 30, height: 20), scale: 2))
        #expect(right.width == 60 && right.height == 40)
        let rightPixel = try firstPixel(of: right)
        #expect(rightPixel == RGB(red: 0, green: 0, blue: 255))
    }

    @Test func cropOfAnItemOutsideTheStripIsNil() throws {
        let image = try twoColorImage(width: 200, height: 62)
        let strip = CGRect(x: 0, y: 0, width: 100, height: 31)
        #expect(StripCapture.crop(image, strip: strip, item: CGRect(x: 500, y: 0, width: 10, height: 10), scale: 2) == nil)
    }

    // MARK: Where the strip is

    @Test func theMainDisplaysStripIsTheTopOfItsFrameInCoreGraphics() throws {
        let geometry = try StripGeometry.of(DisplayFixtures.deskMain, in: .desk)
        #expect(geometry.strip == CGRect(x: 0, y: 0, width: 3360, height: 31))
        #expect(geometry.sourceRect == CGRect(x: 0, y: 0, width: 3360, height: 31))
        #expect(geometry.pixelSize == CGSize(width: 6720, height: 62))
    }

    @Test func aDisplayLeftOfTheMainOneGivesItsStripInGlobalAndLocalPoints() throws {
        // The LG, if it had a menu bar: its top is at CoreGraphics y = -491, and it starts at x = -1800.
        let withBar = DisplayInfo(uuid: "lg", name: "LG", frame: DisplayFixtures.deskPortrait.frame,
                                  visibleFrame: CGRect(x: -1800, y: -819, width: 1800, height: 3200 - 24),
                                  scale: 2, notch: nil, isBuiltIn: false, isMain: false)
        let layout = DisplayLayout(displays: [DisplayFixtures.deskMain, withBar])
        let geometry = try StripGeometry.of(withBar, in: layout)
        #expect(geometry.strip == CGRect(x: -1800, y: -491, width: 1800, height: 24))
        #expect(geometry.sourceRect == CGRect(x: 0, y: 0, width: 1800, height: 24), "local to the display")
    }

    @Test func aDisplayThatReportsNoMenuBarHasNoStrip() {
        #expect(throws: StripCaptureError.noMenuBar) { try StripGeometry.of(DisplayFixtures.deskPortrait, in: .desk) }
    }

    @Test func theNotchedLaptopsStripIsItsFullWidth() throws {
        let geometry = try StripGeometry.of(DisplayFixtures.laptopAlone, in: .laptop)
        #expect(geometry.strip == CGRect(x: 0, y: 0, width: 1512, height: 32))
    }
}
