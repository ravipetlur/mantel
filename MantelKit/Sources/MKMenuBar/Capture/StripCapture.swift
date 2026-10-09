import CoreGraphics
import Foundation
import MKCore
import ScreenCaptureKit

public enum StripCaptureError: Error, Equatable, LocalizedError {
    /// The display reports no menu bar (it has none drawn on it, or it is set to hide).
    case noMenuBar
    /// ScreenCaptureKit has no display with this display's UUID.
    case displayNotFound
    /// Screen Recording isn't granted, or the system refused; the text says what it said.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .noMenuBar: "That display shows no menu bar to capture."
        case .displayNotFound: "macOS doesn't list that display for capture. Reconnect it and try again."
        case .failed(let reason): "The menu bar couldn't be captured: \(reason) Check that Screen Recording is on for Mantel."
        }
    }
}

/// Where a display's menu bar strip is, in the three spaces capturing it needs.
struct StripGeometry: Equatable {
    /// The strip in CoreGraphics global points: the space Accessibility frames are in.
    let strip: CGRect
    /// The strip in points from the display's own top-left corner: what ScreenCaptureKit's `sourceRect` is.
    let sourceRect: CGRect
    /// The size of the captured image, in pixels.
    let pixelSize: CGSize

    static func of(_ display: DisplayInfo, in layout: DisplayLayout) throws(StripCaptureError) -> StripGeometry {
        let appKitStrip = layout.menuBarStrip(of: display)
        guard !appKitStrip.isEmpty else { throw .noMenuBar }
        let strip = layout.cgRect(fromAppKit: appKitStrip)
        let origin = layout.cgRect(fromAppKit: display.frame).origin
        return StripGeometry(strip: strip,
                             sourceRect: strip.offsetBy(dx: -origin.x, dy: -origin.y),
                             pixelSize: CGSize(width: (strip.width * display.scale).rounded(),
                                               height: (strip.height * display.scale).rounded()))
    }
}

/// Which part of a strip's image an item is, in pixels. Pure arithmetic, so it is tested on its own.
public enum CropMath {
    /// The pixels of `item` in an image of `strip`, which is `scale` pixels to the point. Both rectangles are in the same
    /// space (CoreGraphics global points, where Accessibility frames are). The rectangle is rounded out to whole pixels and
    /// cut at the strip's edges, with its origin at the image's top-left corner. Nil when the item has no area, isn't on the
    /// strip, or `scale` is not positive.
    public static func pixelRect(strip: CGRect, item: CGRect, scale: CGFloat) -> CGRect? {
        guard scale > 0, !strip.isEmpty, !item.isEmpty else { return nil }
        let visible = item.intersection(strip)
        guard !visible.isNull, !visible.isEmpty else { return nil }

        let minX = ((visible.minX - strip.minX) * scale).rounded(.down)
        let minY = ((visible.minY - strip.minY) * scale).rounded(.down)
        let maxX = min(((visible.maxX - strip.minX) * scale).rounded(.up), (strip.width * scale).rounded(.up))
        let maxY = min(((visible.maxY - strip.minY) * scale).rounded(.up), (strip.height * scale).rounded(.up))
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Takes a picture of a display's menu bar. Screen Recording is optional for Mantel: without it this throws, and the item
/// pictures fall back to the app's icon.
public protocol StripCapturing: Sendable {
    func capture(display: DisplayInfo, layout: DisplayLayout) async throws -> CGImage
}

/// The real one, through ScreenCaptureKit.
public struct StripCapture: StripCapturing {
    public init() {}

    /// The menu bar strip of `display` as an image, `display.scale` pixels to the point.
    public func capture(display: DisplayInfo, layout: DisplayLayout) async throws -> CGImage {
        let geometry = try StripGeometry.of(display, in: layout)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let target = content.displays.first(where: { Self.uuid(of: $0.displayID) == display.uuid }) else {
                throw StripCaptureError.displayNotFound
            }
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = geometry.sourceRect
            configuration.width = Int(geometry.pixelSize.width)
            configuration.height = Int(geometry.pixelSize.height)
            configuration.showsCursor = false
            let filter = SCContentFilter(display: target, excludingWindows: [])
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch let error as StripCaptureError {
            throw error
        } catch {
            throw StripCaptureError.failed(error.localizedDescription)
        }
    }

    /// The part of a strip's image that an item is, or nil when it isn't on the strip (see `CropMath`).
    public static func crop(_ image: CGImage, strip: CGRect, item: CGRect, scale: CGFloat) -> CGImage? {
        guard let rect = CropMath.pixelRect(strip: strip, item: item, scale: scale) else { return nil }
        return image.cropping(to: rect)
    }

    private static func uuid(of id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
