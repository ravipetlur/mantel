import CoreGraphics
import Foundation
import MKCommands
import MKCore

/// `icon-capture`: pictures of the icons on each shown bar, and what taking them does to the menu bar. It captures the screen (and needs
/// Screen Recording for that), and changes nothing.
///
/// - **For each bar that is shown:**
///   - the identifiers of the system's items are read once (one read of MenuBarAgent's windows), and the bar is captured once
///     (`captureMs`);
///   - MenuBarAgent is read every 250 ms for 3 s: `indicatorAppeared` is whether an item of the system's that wasn't there appeared (a
///     recording indicator, say), `indicatorMs` is when, and `indicatorIdentifiers` are what appeared (the system's own names);
///   - every icon that is drawn, tied to a slot and not out of the way is cut out at its slot and matted (`IconMatting`). The raw crop, the
///     matted icon and the icon cut to its content are saved in the Probes folder as `icon-<stamp>-<display>-<n>-raw.png`, `-matted.png`
///     and `-trimmed.png`. The pictures stay on this Mac.
/// - **Records** for each bar: `barAppearance`, `itemCount`, `coverage` (middle and smallest), `monochromeCount`, `lowConfidenceCount`
///   and each icon's trimmed size in pixels. **An icon is `n`**, the number in its file names, and nothing says whose it is, except for
///   the test item's and Mantel's own.
enum IconCaptureProbe {
    static let indicatorReadInterval: Duration = .milliseconds(250)
    static let indicatorWatchMs = 3000.0
    /// What the system's own items' identifiers start with.
    static let systemPrefix = "com.apple.menuextra."

    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        let platform = context.platform
        let granted = platform.screenRecordingGranted()
        recorder.measure("screenRecordingGranted", granted)
        recorder.measure("bars", .array([]))
        guard granted else {
            recorder.note("Screen Recording isn't granted to Mantel, so no capture was tried.")
            return
        }

        let layout = await context.layoutProvider()
        let snapshot = await context.snapshot()
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(snapshot.matchInput(ownBundleID: platform.ownBundleID), memory: &memory)
        let geometries = snapshot.bars()
        let shown = BarVisibility.shownBars(platform.windowList.onScreenWindows(), bars: geometries)
        for problem in snapshot.problems { recorder.note(problem) }

        let stamp = ProbeReport.timestamp(startedAt: context.startedAt)
        var bars: [JSONValue] = []
        var saved = 0
        do {
            for (index, display) in layout.displays.enumerated() {
                guard let bar = geometries.first(where: { $0.displayUUID == display.uuid }), shown.contains(display.uuid) else {
                    recorder.note("Display \(index + 1) shows no menu bar, so it was skipped.")
                    continue
                }
                let result = try await captureBar(bar, display: display, layout: layout, index: index, inventory: inventory, stamp: stamp,
                                                  context: context, recorder: &recorder)
                bars.append(result.json)
                saved += result.saved
            }
        } catch is CancellationError {
            recorder.note("The probe was cut short.")
        } catch {
            recorder.fail("The probe stopped: \(error.localizedDescription)")
        }
        recorder.measure("bars", .array(bars))
        recorder.measure("picturesSaved", saved)
        recorder.note("Each icon is n in the file names of its pictures, in the order of its place on the bar, left to right.")
    }

    // MARK: One bar

    private struct BarResult {
        var json: JSONValue
        var saved: Int
    }

    private static func captureBar(_ bar: MenuBarGeometry, display: DisplayInfo, layout: DisplayLayout, index: Int, inventory: Inventory,
                                   stamp: String, context: ProbeContext, recorder: inout ProbeRecorder) async throws -> BarResult {
        let platform = context.platform
        var record: [String: JSONValue] = ["display": .number(Double(index + 1)), "displayID": .string(display.uuid)]

        // What the system's items are before the capture.
        let before = systemIdentifiers(await context.agentSnapshot())

        let started = context.clock.now()
        let image: CGImage
        do {
            image = try await platform.capture.capture(bar: bar, display: display, layout: layout)
        } catch {
            recorder.fail("Display \(index + 1): \(error.localizedDescription)")
            record["captureMs"] = .null
            return BarResult(json: .object(record), saved: 0)
        }
        record["captureMs"] = .number(context.milliseconds(since: started))

        // And what they are for the next three seconds.
        var appeared: Set<String> = []
        var indicatorMs: Double?
        while true {
            try Task.checkCancellation()
            let now = systemIdentifiers(await context.agentSnapshot())
            let elapsed = context.milliseconds(since: started)
            let new = now.subtracting(before)
            if !new.isEmpty {
                if indicatorMs == nil { indicatorMs = elapsed }
                appeared.formUnion(new)
            }
            if elapsed >= indicatorWatchMs { break }
            try await context.clock.sleep(for: indicatorReadInterval)
        }
        record["indicatorAppeared"] = .bool(indicatorMs != nil)
        record["indicatorMs"] = ProbeJSON.number(indicatorMs)
        record["indicatorIdentifiers"] = .array(appeared.sorted().map(JSONValue.string))

        // The icons.
        let own: Set<String> = [context.fixtureBundleID, platform.ownBundleID]
        let drawn = inventory.items.compactMap { item -> (item: MenuBarItem, slot: CGRect)? in
            guard !item.isConcealed, !item.overflowedOn.contains(display.uuid), let slot = item.frames[display.uuid] else { return nil }
            return (item, slot)
        }.sorted { $0.slot.minX < $1.slot.minX }

        var icons: [JSONValue] = []
        var coverages: [Double] = []
        var appearances: [BarAppearance] = []
        var monochrome = 0, lowConfidence = 0, files = 0
        for (number, entry) in drawn.enumerated() {
            guard let crop = StripCapture.crop(image, bar: bar, item: entry.slot, scale: display.scale) else { continue }
            var icon: [String: JSONValue] = ["n": .number(Double(number))]
            if own.contains(entry.item.ownerBundleID) || entry.item.isMantel { icon["id"] = .string(entry.item.id.string) }
            files += save(crop, as: "icon-\(stamp)-\(display.uuid)-\(number)-raw", context: context, recorder: &recorder)
            if let matted = IconMatting.matte(crop) {
                let trimmed = IconMatting.trimmed(matted)
                files += save(matted.image, as: "icon-\(stamp)-\(display.uuid)-\(number)-matted", context: context, recorder: &recorder)
                files += save(trimmed, as: "icon-\(stamp)-\(display.uuid)-\(number)-trimmed", context: context, recorder: &recorder)
                coverages.append(matted.coverage)
                appearances.append(matted.barAppearance)
                if matted.isMonochrome { monochrome += 1 }
                if matted.lowConfidence { lowConfidence += 1 }
                icon["matted"] = .bool(true)
                icon["coverage"] = .number(matted.coverage)
                icon["monochrome"] = .bool(matted.isMonochrome)
                icon["lowConfidence"] = .bool(matted.lowConfidence)
                icon["trimmedWidth"] = .number(Double(trimmed.width))
                icon["trimmedHeight"] = .number(Double(trimmed.height))
            } else {
                icon["matted"] = .bool(false)
            }
            icons.append(.object(icon))
        }
        record["itemCount"] = .number(Double(icons.count))
        record["scale"] = .number(Double(display.scale))
        record["barAppearance"] = ProbeJSON.text(dominant(appearances)?.rawValue)
        record["coverage"] = .object(["p50": ProbeJSON.number(median(coverages)), "min": ProbeJSON.number(coverages.min())])
        record["monochromeCount"] = .number(Double(monochrome))
        record["lowConfidenceCount"] = .number(Double(lowConfidence))
        record["icons"] = .array(icons)
        return BarResult(json: .object(record), saved: files)
    }

    // MARK: Helpers

    /// The identifiers of the system's own items in every window of MenuBarAgent's.
    private static func systemIdentifiers(_ snapshot: MenuBarSnapshot) -> Set<String> {
        Set(snapshot.allSlots.compactMap(\.identifier).filter { $0.hasPrefix(systemPrefix) })
    }

    /// The middle of the numbers (the mean of the two in the middle when there is an even count); nil for none.
    static func median(_ numbers: [Double]) -> Double? {
        let sorted = numbers.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// The appearance most of the icons say the bar has: light when they are as many as dark.
    private static func dominant(_ appearances: [BarAppearance]) -> BarAppearance? {
        guard !appearances.isEmpty else { return nil }
        let light = appearances.filter { $0 == .light }.count
        return light >= appearances.count - light ? .light : .dark
    }

    /// Writes a picture into the Probes folder; 1 when it was written, 0 when it wasn't (and the report says so).
    private static func save(_ image: CGImage, as name: String, context: ProbeContext, recorder: inout ProbeRecorder) -> Int {
        guard let data = IconMatting.pngData(image) else {
            recorder.fail("A picture couldn't be made into a file.")
            return 0
        }
        do {
            try AtomicFile.ensureFolder(context.paths.probes)
            try AtomicFile.write(data, to: AtomicFile.unusedURL(in: context.paths.probes, base: name, pathExtension: "png"))
            return 1
        } catch {
            recorder.fail("A picture couldn't be saved: \(error.localizedDescription)")
            return 0
        }
    }
}
