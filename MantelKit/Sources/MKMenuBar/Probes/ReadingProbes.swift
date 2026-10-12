import CoreGraphics
import Foundation
import ImageIO
import MKCommands
import MKCore
import UniformTypeIdentifiers

/// `inventory`: everything the reader can see, with the raw tree under MenuBarAgent, saved whole beside the report. It also says:
/// - `spaceWindows`: for each of MenuBarAgent's windows, its frame, the names and values of its window-level attributes
///   (`AXRole`, `AXSubrole`, `AXMain`, `AXFocused`, `AXIdentifier` and every attribute that holds a true or false) and how many slots
///   it has, so that the window of the active Space can be told from the others;
/// - `agentOnScreen`: the windows of MenuBarAgent's process that are on screen, by number, level, bounds and opacity;
/// - `menuBarWindows`: every window on screen at the main menu's level or the status items' (24 and 25), with its owner's bundle ID
///   and its bounds;
/// - `systemModules`: every `com.apple.menuextra.*` identifier in the menu bar;
/// - `frontMenuFrames`: how many menus the front app has, whose frames are in the snapshot file (`MenuBarSnapshot.frontMenuFrames`).
///
/// It only reads, and reads the window list for owners and levels, never for titles.
enum InventoryProbe {
    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        var snapshot = await context.snapshot(includeRawTree: true)
        // Where the front app's menus are (frames only), so that a read can be replayed with the menus rule.
        if let pid = context.platform.frontAppPID() {
            snapshot = snapshot.withFrontMenuFrames(await context.reader.menuFrames(ofPID: pid))
        }
        recorder.measure("frontMenuFrames", snapshot.frontMenuFrames.count)
        recorder.measure("agentWindowCount", snapshot.agentWindows.count)
        recorder.measure("slotsPerWindow", .array(snapshot.agentWindows.map { .number(Double($0.slots.count)) }))
        recorder.measure("appsWithExtras", snapshot.apps.filter { !$0.items.isEmpty }.count)
        recorder.measure("timedOutApps", strings: snapshot.apps.filter(\.timedOut).map { $0.bundleID ?? "pid \($0.pid)" })
        for problem in snapshot.problems { recorder.note(problem) }

        let details = await context.reader.agentWindowDetails()
        recorder.measure("spaceWindows", .array(details.map { detail in
            .object(["frame": NotchCoordinatesProbe.rect(detail.frame), "attributes": .object(detail.attributes),
                     "slotCount": .number(Double(detail.slotCount))])
        }))
        let windows = context.platform.windowList.onScreenWindows()
        recorder.measure("agentOnScreen", .array(windows.filter { $0.ownerBundleID == MenuBarReader.menuBarAgentBundleID }.map { window in
            .object(["number": .number(Double(window.number)), "layer": .number(Double(window.layer)),
                     "bounds": NotchCoordinatesProbe.rect(window.bounds), "alpha": .number(window.alpha)])
        }))
        recorder.measure("menuBarWindows", .array(windows.filter { $0.layer == WindowLevels.mainMenu || $0.layer == WindowLevels.statusBar }.map { window in
            .object(["owner": window.ownerBundleID.map(JSONValue.string) ?? .null, "layer": .number(Double(window.layer)),
                     "bounds": NotchCoordinatesProbe.rect(window.bounds)])
        }))
        let prefix = "com.apple.menuextra."
        recorder.measure("systemModules", strings: Set(snapshot.allSlots.compactMap(\.identifier).filter { $0.hasPrefix(prefix) }).sorted())

        let name = "inventory-\(ProbeReport.timestamp(startedAt: context.startedAt))-snapshot"
        do {
            try AtomicFile.ensureFolder(context.paths.probes)
            let url = AtomicFile.unusedURL(in: context.paths.probes, base: name, pathExtension: "json")
            try AtomicFile.write(try JSONCoding.encoder().encode(snapshot), to: url)
            recorder.measure("snapshotFile", url.lastPathComponent)
        } catch {
            recorder.fail("The snapshot couldn't be saved: \(error.localizedDescription)")
        }
    }
}

/// `overflow`: what is in the « overflow, and whether there is a « at all.
enum OverflowProbe {
    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        let snapshot = await context.snapshot()
        let overflowed = OverflowAnalysis.overflowed(in: snapshot)
        recorder.measure("chevronPresent", snapshot.allSlots.contains(where: \.isOverflowChevron))
        recorder.measure("overflowedItems", .array(overflowed.map { item in
            .object(["bundleID": item.bundleID.map(JSONValue.string) ?? .null, "index": .number(Double(item.index))])
        }))
        recorder.measure("framelessSlots", snapshot.allSlots.filter { $0.frame.map(\.isEmpty) ?? true }.count)
        for problem in snapshot.problems { recorder.note(problem) }
    }
}

/// `screen-share`: the identifiers and descriptions of the slots on the menu bar, so that a run `before` and one `during`
/// show what appears while the screen is being shared.
enum ScreenShareProbe {
    private static let phaseKey = "phase"

    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        guard let phase = context.options.string(phaseKey), phase == "before" || phase == "during" else {
            recorder.fail("Say which phase: --phase before or --phase during.")
            return
        }
        let snapshot = await context.snapshot()
        let identifiers = Set(snapshot.allSlots.compactMap(\.identifier).filter { !$0.isEmpty })
        let descriptions = Set(snapshot.allSlots.compactMap(\.description).filter { !$0.isEmpty })
        recorder.measure(phaseKey, phase)
        recorder.measure("identifiers", strings: identifiers.sorted())
        recorder.measure("descriptions", strings: descriptions.sorted())
        for problem in snapshot.problems { recorder.note(problem) }

        guard phase == "during" else { return }
        guard let earlier = context.store.latest(.screenShare, matching: { $0.measurements[phaseKey] == .string("before") }) else {
            recorder.note("No earlier report from before sharing was found. Run `mantel probe screen-share --phase before` first.")
            return
        }
        let earlierIdentifiers = Set(earlier.strings("identifiers") ?? [])
        let earlierDescriptions = Set(earlier.strings("descriptions") ?? [])
        recorder.measure("comparedWith", ProbeReport.fileName(for: .screenShare, startedAt: earlier.startedAt))
        recorder.measure("newIdentifiers", strings: identifiers.subtracting(earlierIdentifiers).sorted())
        recorder.measure("newDescriptions", strings: descriptions.subtracting(earlierDescriptions).sorted())
    }
}

/// `menu-bar-height`: every height of the menu bar that can be read, display by display. Only reads.
enum MenuBarHeightProbe {
    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        let layout = await context.layoutProvider()
        let snapshot = await context.snapshot()
        let thickness = await context.platform.statusBarThickness()
        recorder.measure("statusBarThickness", thickness)

        var displays: [JSONValue] = []
        for display in layout.displays {
            let area = layout.cgRect(fromAppKit: display.frame)
            let window = snapshot.agentWindows.first { area.contains($0.frame.origin) }
            displays.append(.object([
                "name": .string(display.name),
                "scale": .number(display.scale),
                "frameMinusVisibleFrame": .number(Double(display.frame.maxY - display.visibleFrame.maxY)),
                "agentWindowHeight": window.map { .number(Double($0.frame.height)) } ?? .null,
            ]))
        }
        recorder.measure("displays", .array(displays))
        recorder.note("statusBarThickness is one number for every display (NSStatusBar.system.thickness).")
        recorder.note("frameMinusVisibleFrame is 0 on a display that reports no menu bar, and while the menu bar is set to hide.")
        recorder.note("agentWindowHeight is MenuBarAgent's window for that display, from Accessibility; nil when the display has none.")
        recorder.note("Nothing is written: the height is read from the system, never set.")
        for problem in snapshot.problems { recorder.note(problem) }
    }
}

/// `capture`: a picture of each display's menu bar strip, and one of each item on it.
enum CaptureProbe {
    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        let granted = context.platform.screenRecordingGranted()
        recorder.measure("screenRecordingGranted", granted)
        recorder.measure("capturedDisplays", 0)
        recorder.measure("crops", 0)
        guard granted else {
            recorder.note("Screen Recording isn't granted to Mantel, so no capture was tried.")
            return
        }

        let layout = await context.layoutProvider()
        let snapshot = await context.snapshot()
        let stamp = ProbeReport.timestamp(startedAt: context.startedAt)
        var captured = 0
        var cropCount = 0
        let bars = snapshot.bars()
        for display in layout.displays {
            guard let bar = bars.first(where: { $0.displayUUID == display.uuid }),
                  let geometry = try? StripGeometry.of(bar, display: display, layout: layout) else {
                recorder.note("\(display.name) has no menu bar, so it was skipped.")
                continue
            }
            do {
                let image = try await context.platform.capture.capture(bar: bar, display: display, layout: layout)
                try save(image, as: "capture-\(stamp)-\(display.uuid)", in: context)
                captured += 1
                for slot in snapshot.allSlots {
                    guard let frame = slot.frame, !frame.isEmpty,
                          geometry.strip.contains(CGPoint(x: frame.midX, y: frame.midY)),
                          let crop = StripCapture.crop(image, bar: bar, item: frame, scale: display.scale) else { continue }
                    try save(crop, as: "crop-\(stamp)-\(cropCount)", in: context)
                    cropCount += 1
                }
            } catch {
                recorder.fail("\(display.name): \(error.localizedDescription)")
            }
        }
        recorder.measure("capturedDisplays", captured)
        recorder.measure("crops", cropCount)
    }

    private static func save(_ image: CGImage, as name: String, in context: ProbeContext) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try AtomicFile.ensureFolder(context.paths.probes)
        try AtomicFile.write(data as Data, to: AtomicFile.unusedURL(in: context.paths.probes, base: name, pathExtension: "png"))
    }
}
