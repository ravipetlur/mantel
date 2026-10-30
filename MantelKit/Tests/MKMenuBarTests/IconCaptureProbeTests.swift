import CoreGraphics
import Foundation
import ImageIO
import MKCommands
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

private let fixtureID = ProbeHarness.fixtureID
private let ownID = ProbeHarness.ownBundleID
private let otherID = ProbeHarness.otherID
private let main = DisplayFixtures.deskMain.uuid

/// The slots of the harness's bar, left to right.
private let slots: [CGRect] = [
    CGRect(x: 3000, y: 0, width: 30, height: 31), CGRect(x: 3100, y: 0, width: 40, height: 31), CGRect(x: 3150, y: 0, width: 40, height: 31),
    CGRect(x: 3200, y: 0, width: 40, height: 31), CGRect(x: 3250, y: 0, width: 40, height: 31), CGRect(x: 3300, y: 0, width: 50, height: 31),
]

/// A capture of the bar: a flat blue strip with a white square, 6 points across, in the middle of each of the slots it is given. It draws
/// pictures of its own, never anything of the screen. It says when it has been asked for, so that a test can have something happen then.
private final class DrawnCapture: StripCapturing {
    private let drawn: [CGRect]
    private let hook = Mutex<(@Sendable () -> Void)?>(nil)

    init(_ drawn: [CGRect] = slots) {
        self.drawn = drawn
    }

    /// What happens when the bar is captured.
    func onCapture(_ body: (@Sendable () -> Void)?) { hook.withLock { $0 = body } }

    func capture(bar: MenuBarGeometry, display: DisplayInfo, layout: DisplayLayout) async throws -> CGImage {
        hook.withLock { $0 }?()
        let geometry = try StripGeometry.of(bar, display: display, layout: layout)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: Int(geometry.pixelSize.width), height: Int(geometry.pixelSize.height), bitsPerComponent: 8,
                                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [0.2, 0.4, 0.6, 1])!)
        context.fill(CGRect(origin: .zero, size: geometry.pixelSize))
        context.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
        let scale = display.scale
        for slot in drawn {
            let centre = CGPoint(x: (slot.midX - bar.rect.minX) * scale, y: geometry.pixelSize.height / 2)
            context.fill(CGRect(x: centre.x - 6, y: centre.y - 6, width: 12, height: 12))
        }
        return context.makeImage()!
    }
}

/// The window the window server keeps on screen while a bar is shown: at the main menu's level, with no owner that has a bundle ID.
private func barIsShown(_ harness: ProbeHarness) {
    harness.windows.setExtra([WindowInfo(number: 500, ownerPID: 1, ownerBundleID: nil, layer: WindowLevels.mainMenu,
                                         bounds: CGRect(x: 0, y: 0, width: 3360, height: 31), alpha: 1)])
}

private func bars(_ report: ProbeReport) -> [[String: JSONValue]] {
    guard case .array(let list)? = report.measurements["bars"] else { return [] }
    return list.compactMap { if case .object(let object) = $0 { object } else { nil } }
}

private func pixelSize(of file: URL) throws -> (width: Int, height: Int) {
    let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    return (image.width, image.height)
}

@Suite("Icon-capture probe", .timeLimit(.minutes(1)))
struct IconCaptureProbeTests {
    private func desk(drawn: [CGRect] = slots) throws -> ProbeHarness {
        let harness = try ProbeHarness.make { platform in platform.capture = DrawnCapture(drawn) }
        barIsShown(harness)
        return harness
    }

    // MARK: What it saves

    @Test func iconCaptureSavesTrimmedImage() async throws {
        let harness = try desk()

        let report = await harness.run(.iconCapture)

        #expect(report.errors.isEmpty, "\(report.errors)")
        let files = harness.probeFiles().filter { $0.hasPrefix("icon-") && $0.hasSuffix(".png") }
        let stamp = ProbeReport.timestamp(startedAt: report.startedAt)
        // Six icons are cut out, and each has three pictures.
        #expect(files.count == 18, "\(files)")
        for number in 0..<6 {
            for kind in ["raw", "matted", "trimmed"] {
                #expect(files.contains("icon-\(stamp)-\(main)-\(number)-\(kind).png"), "\(number) \(kind)")
            }
        }
        // The trimmed picture of the test item's first icon is the square that was drawn: 12 pixels across (6 points at 2x).
        let trimmed = harness.probesFolder.appending(path: "icon-\(stamp)-\(main)-1-trimmed.png")
        let size = try pixelSize(of: trimmed)
        #expect(size.width == 12 && size.height == 12, "the content and nothing of the bar round it: \(size)")
        // The raw crop is the whole slot at 2x.
        let raw = try pixelSize(of: harness.probesFolder.appending(path: "icon-\(stamp)-\(main)-1-raw.png"))
        #expect(raw.width == 80 && raw.height == 62)
        // And the matted one is as big as the crop.
        let matted = try pixelSize(of: harness.probesFolder.appending(path: "icon-\(stamp)-\(main)-1-matted.png"))
        #expect(matted.width == 80 && matted.height == 62)
        #expect(report.number("picturesSaved") == 18)
    }

    @Test func eachBarIsRecordedWithWhatWasLearnedOfItsIcons() async throws {
        let harness = try desk()
        let report = await harness.run(.iconCapture)

        let recorded = try #require(bars(report).first)
        #expect(bars(report).count == 1, "the portrait display has no bar")
        #expect(recorded["itemCount"] == .number(6))
        #expect(recorded["scale"] == .number(2))
        #expect(recorded["barAppearance"] == .string("dark"), "a blue bar that is darker than half")
        #expect(recorded["captureMs"] != nil && recorded["captureMs"] != .null)
        let coverage = try #require(recorded["coverage"])
        guard case .object(let numbers) = coverage, case .number(let median)? = numbers["p50"], case .number(let smallest)? = numbers["min"] else {
            Issue.record("coverage has a middle and a smallest")
            return
        }
        // 144 pixels of 80 by 62 (the 50-point clock's slot is wider: 100 by 62).
        #expect(smallest < median && median > 0.02 && median < 0.04, "\(median)")
        #expect(recorded["monochromeCount"] != nil && recorded["lowConfidenceCount"] != nil)
        guard case .array(let icons)? = recorded["icons"] else {
            Issue.record("icons")
            return
        }
        #expect(icons.count == 6)
        for case .object(let icon) in icons {
            #expect(icon["trimmedWidth"] == .number(12) && icon["trimmedHeight"] == .number(12))
            #expect(icon["matted"] == .bool(true))
        }
    }

    @Test func aCropWithNothingInItIsRawOnly() async throws {
        // Only the first slot has an icon in it: the rest are the bar and nothing, which can't be matted.
        let harness = try desk(drawn: [slots[0]])
        let report = await harness.run(.iconCapture)
        let recorded = try #require(bars(report).first)
        guard case .array(let icons)? = recorded["icons"] else {
            Issue.record("icons")
            return
        }
        let matted = icons.filter { if case .object(let icon) = $0, icon["matted"] == .bool(true) { true } else { false } }
        #expect(icons.count == 6 && matted.count == 1)
        let files = harness.probeFiles().filter { $0.hasPrefix("icon-") && $0.hasSuffix(".png") }
        #expect(files.filter { $0.hasSuffix("-raw.png") }.count == 6)
        #expect(files.filter { $0.hasSuffix("-trimmed.png") }.count == 1)
    }

    // MARK: Who it names

    @Test func iconCaptureReportsNoOtherAppsIDs() async throws {
        let harness = try desk()
        let report = await harness.run(.iconCapture)
        let json = String(decoding: try JSONCoding.encoder().encode(report), as: UTF8.self)

        #expect(!json.contains(otherID), "the other app is an icon like the rest, and is n")
        #expect(!json.contains("controlcenter") && !json.contains("clock") && !json.contains("menuextra"), "so are the system's")
        guard case .array(let icons)? = bars(report).first?["icons"] else {
            Issue.record("icons")
            return
        }
        let named = icons.compactMap { value -> String? in
            if case .object(let icon) = value, case .string(let id)? = icon["id"] { id } else { nil }
        }
        // The test item's two and Mantel's own are named; nobody else's is.
        #expect(Set(named) == [ItemID(bundleID: fixtureID, key: .identifier("one")).string, ItemID(bundleID: fixtureID, key: .identifier("two")).string,
                               ItemID(bundleID: ownID, key: .identifier("\(ownID).dot")).string])
        #expect(icons.count == 6)
        // The file names say n and the display, and never an app.
        for file in harness.probeFiles() { #expect(!file.contains(otherID) && !file.contains(fixtureID), "\(file)") }
    }

    // MARK: The indicator

    @Test func anItemOfTheSystemsThatAppearsIsTheIndicator() async throws {
        let capture = DrawnCapture()
        let harness = try ProbeHarness.make { platform in platform.capture = capture }
        barIsShown(harness)
        let ax = harness.ax
        let window = harness.window
        capture.onCapture {
            // The capture makes the system add an item to the bar.
            ax.addSlot(in: window, identifier: "com.apple.menuextra.screencapture", frame: CGRect(x: 3360 - 400, y: 0, width: 30, height: 31))
        }

        let report = await harness.run(.iconCapture)

        let recorded = try #require(bars(report).first)
        #expect(recorded["indicatorAppeared"] == .bool(true))
        #expect(recorded["indicatorMs"] != .null, "when it was first seen")
        #expect(recorded["indicatorIdentifiers"] == .array([.string("com.apple.menuextra.screencapture")]))
    }

    @Test func noNewItemMeansNoIndicator() async throws {
        let harness = try desk()
        let report = await harness.run(.iconCapture)
        let recorded = try #require(bars(report).first)
        #expect(recorded["indicatorAppeared"] == .bool(false))
        #expect(recorded["indicatorMs"] == .null)
        #expect(recorded["indicatorIdentifiers"] == .array([]))
    }

    @Test func theBarIsWatchedForThreeSecondsEveryQuarterSecond() async throws {
        let clock = SteppingClock()
        let harness = try ProbeHarness.make(clock: clock, readCost: .zero) { platform in
            platform.capture = DrawnCapture()
        }
        barIsShown(harness)
        let before = clock.now()
        let report = await harness.run(.iconCapture)
        let elapsed = clock.now().timeIntervalSince(before)
        #expect(elapsed >= 3 && elapsed < 3.5, "3 s of reads, 250 ms apart: \(elapsed)")
        #expect(report.errors.isEmpty)
    }

    // MARK: Refusals

    @Test func withoutScreenRecordingNothingIsCaptured() async throws {
        let harness = try desk()
        harness.screenRecording.set(false)
        let report = await harness.run(.iconCapture)
        #expect(report.errors.isEmpty)
        #expect(report.bool("screenRecordingGranted") == false)
        #expect(bars(report).isEmpty)
        #expect(harness.probeFiles().filter { $0.hasPrefix("icon-") && $0.hasSuffix(".png") }.isEmpty)
        #expect(report.notes.contains { $0.contains("Screen Recording isn't granted") })
    }

    @Test func aBarThatIsNotShownIsSkipped() async throws {
        // A full-screen app has the display: no window of the bar is on screen.
        let harness = try ProbeHarness.make { platform in platform.capture = DrawnCapture() }
        let report = await harness.run(.iconCapture)
        #expect(bars(report).isEmpty)
        #expect(report.notes.contains { $0.contains("shows no menu bar") })
        #expect(harness.probeFiles().filter { $0.hasPrefix("icon-") && $0.hasSuffix(".png") }.isEmpty)
    }

    @Test func aCaptureThatFailsIsAnErrorAndNothingElseIsSaved() async throws {
        let harness = try ProbeHarness.make()
        barIsShown(harness)
        harness.capture.fail(with: .failed("no"))
        let report = await harness.run(.iconCapture)
        #expect(report.errors.count == 1 && report.errors[0].contains("Display 1"))
        #expect(harness.probeFiles().filter { $0.hasPrefix("icon-") && $0.hasSuffix(".png") }.isEmpty)
    }

    @Test func itChangesNothing() async throws {
        let harness = try desk()
        let report = await harness.run(.iconCapture)
        #expect(!ProbeRunner.changesState(.iconCapture))
        #expect(report.restored)
        #expect(harness.allowlist.calls.isEmpty && harness.poster.clicks.isEmpty && harness.relauncher.asked.isEmpty)
        #expect(harness.preferences.writes.isEmpty)
        #expect(await harness.journal.records().isEmpty)
    }
}
