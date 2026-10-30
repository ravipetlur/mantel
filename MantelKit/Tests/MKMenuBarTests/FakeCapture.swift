import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// A capture that makes a flat image of the strip's size, and notes which displays it was asked for. A test can have it paint discs in
/// rectangles (CoreGraphics global points) on a bar of another gray, and hang or be slow (on a clock) before it answers.
final class FakeCapture: StripCapturing {
    private struct Look {
        var paint: [CGRect] = []
        var colour = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [1, 0, 0, 1])!
        var level: CGFloat?
        var hangs = false
        var delay: Duration?
        var held: Gate?
        var entered: Gate?
    }

    private let asked = Mutex<[String]>([])
    private let failure = Mutex<StripCaptureError?>(nil)
    private let look = Mutex(Look())
    private let clock: (any Clock)?

    init(clock: (any Clock)? = nil) { self.clock = clock }

    var displays: [String] { asked.withLock { $0 } }
    func fail(with error: StripCaptureError?) { failure.withLock { $0 = error } }
    func paint(_ rects: [CGRect]) { look.withLock { $0.paint = rects } }
    func setColour(_ colour: CGColor) { look.withLock { $0.colour = colour } }
    func setLevel(_ level: CGFloat?) { look.withLock { $0.level = level } }
    func hang(_ hangs: Bool) { look.withLock { $0.hangs = hangs } }
    /// Answers after this long on the clock, taking the picture when it comes back, as a capture that can't be cancelled does: a caller
    /// that gives up on it doesn't stop it.
    func delay(_ delay: Duration?) { look.withLock { $0.delay = delay } }
    /// Waits at the gate before it answers, until a test lets it through: a slow capture that the test can change the bar during.
    /// `entered` is opened when a capture has come to the gate.
    func hold(at gate: Gate?, entered: Gate? = nil) { look.withLock { $0.held = gate; $0.entered = entered } }

    func capture(bar: MenuBarGeometry, display: DisplayInfo, layout: DisplayLayout) async throws -> CGImage {
        asked.withLock { $0.append(display.uuid) }
        if let error = failure.withLock({ $0 }) { throw error }
        let now = look.withLock { $0 }
        if now.hangs, let clock { try await clock.sleep(for: .seconds(10)) }
        if let delay = now.delay, let clock { try await Task.detached { try await clock.sleep(for: delay) }.value }
        if let gate = now.held {
            now.entered?.open()
            await Task.detached { await gate.wait() }.value
        }
        let geometry = try StripGeometry.of(bar, display: display, layout: layout)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: Int(geometry.pixelSize.width), height: Int(geometry.pixelSize.height),
                                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let components: [CGFloat] = now.level.map { [$0, $0, $0, 1] } ?? [0.2, 0.4, 0.6, 1]
        context.setFillColor(CGColor(colorSpace: space, components: components)!)
        context.fill(CGRect(origin: .zero, size: geometry.pixelSize))
        context.setFillColor(now.colour)
        for rect in now.paint {
            // Pixels from the strip's top-left; CoreGraphics draws from the bottom-left. The disc is 6 points inside the rectangle.
            let x = (rect.minX - bar.rect.minX) * display.scale
            let yFromTop = (rect.minY - bar.rect.minY) * display.scale
            let inset = 6 * display.scale
            let height = rect.height * display.scale
            context.fillEllipse(in: CGRect(x: x + inset, y: geometry.pixelSize.height - yFromTop - height + inset,
                                           width: rect.width * display.scale - inset * 2, height: height - inset * 2))
        }
        return context.makeImage()!
    }
}
