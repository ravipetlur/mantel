import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Synchronization

@testable import MKMenuBar

let imageSRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func imageColour(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(colorSpace: imageSRGB, components: [red, green, blue, 1])!
}

/// A matted icon: a disc `radius` pixels across in `colour`, on a gray bar of `level`, in a crop `width` by `height` pixels.
func mattedDisc(colour: CGColor = imageColour(1, 0, 0), level: CGFloat = 0.2, width: Int = 72, height: Int = 60,
                radius: CGFloat = 16) -> MattedIcon {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: imageSRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(colorSpace: imageSRGB, components: [level, level, level, 1])!)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(colour)
    context.fillEllipse(in: CGRect(x: CGFloat(width) / 2 - radius, y: CGFloat(height) / 2 - radius, width: radius * 2, height: radius * 2))
    return IconMatting.matte(context.makeImage()!)!
}

enum CollectorWorld {
    static let display = "D1"
    static let barRect = CGRect(x: 0, y: 0, width: 1000, height: 24)

    static func slot(_ index: Int) -> CGRect { CGRect(x: 100 + CGFloat(index) * 60, y: 0, width: 30, height: 24) }

    static func displayLayout() -> DisplayLayout {
        DisplayLayout(displays: [DisplayInfo(uuid: display, name: "Test", frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                             visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 776), scale: 2, notch: nil,
                                             isBuiltIn: true, isMain: true)])
    }

    static func barWindow() -> WindowInfo {
        WindowInfo(number: 1, ownerPID: 50, ownerBundleID: nil, layer: WindowLevels.mainMenu, bounds: barRect, alpha: 1)
    }

    static func item(_ id: ItemID, bundleID: String, slot: Int?, overflowed: Bool = false, mantel: Bool = false, kind: OwnItemKind? = nil,
                     stray: CGRect? = nil) -> MenuBarItem {
        MenuBarItem(id: id, ownerBundleID: bundleID, appName: nil, label: nil, frames: slot.map { [display: Self.slot($0)] } ?? [:],
                    overflowedOn: overflowed ? [display] : [], isMantel: mantel, strayFrames: stray.map { [display: $0] } ?? [:],
                    ownKind: kind)
    }

    static func inventory(_ items: [MenuBarItem], unanswered: Set<String> = [], incomplete: Set<String> = []) -> Inventory {
        Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: [MenuBarGeometry(displayUUID: display, rect: barRect, notch: nil)],
                  items: items, chevrons: [:], reach: [], problems: [], unansweredApps: unanswered, incompleteApps: incomplete)
    }

    static func id(_ name: String) -> ItemID { ItemID(bundleID: "com.example.\(name)", key: .identifier(name)) }
}
