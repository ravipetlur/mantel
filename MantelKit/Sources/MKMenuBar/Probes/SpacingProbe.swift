import CoreGraphics
import Foundation
import MKCommands
import MKCore

/// `spacing`: whether macOS changes how wide icons are when the two icon spacing preferences change, and for which icons.
///
/// - **Reads** both preferences (`before`: the number each holds, or null where it holds none) and measures the width of the slots of the
///   test item's items on every display, and of the clock's.
/// - **Writes** Small (8 and 8) through `DefaultsAccess`, as a temporary change, relaunches the test item and nothing else, waits for its
///   items to come back (5 s at most), and measures again: `after`, and `systemChanged` (the clock's width changed, which an app that
///   wasn't relaunched can't have made it do).
/// - **Puts the preferences back**, relaunches the test item again and measures once more: `restoredWidthsMatch` (every width within a
///   point of what it was before).
/// - The test item is relaunched with the items it has now (`--single`, nothing, or `--extra N`). No other app is ever asked to quit.
enum SpacingProbe {
    /// How long the test item's items are waited for after it is opened again.
    static let waitForItemsMs = 5000.0
    /// How far a width may be from what it was and be the same, in points.
    static let tolerance: CGFloat = 1

    /// The slots' widths on each display, in points.
    private struct Widths: Equatable {
        /// Display UUID, then item name, then the width of the slot the item is in. An item that isn't in a slot has none.
        var items: [String: [String: CGFloat]] = [:]
        /// Display UUID, then the width of the clock's slot.
        var clocks: [String: CGFloat] = [:]

        var json: JSONValue {
            var object: [String: JSONValue] = [:]
            for display in Set(items.keys).union(clocks.keys) {
                object[display] = .object([
                    "testItem": .object((items[display] ?? [:]).mapValues { JSONValue.number(Double($0)) }),
                    "clock": ProbeJSON.number(clocks[display]),
                ])
            }
            return .object(object)
        }
    }

    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        let platform = context.platform
        guard let count = context.fixtureItemCount() else {
            recorder.fail("MantelTestItem isn't running, or has no items in the menu bar. Open it first.")
            return
        }
        let names = TestItemNames.names(itemCount: count)
        guard let candidate = context.fixtureRelaunchCandidate(arguments: TestItemNames.launchArguments(itemCount: count)) else {
            recorder.fail("MantelTestItem has no app to open again. Open it from /Applications first.")
            return
        }
        let domain = PreferencesDomain.globalCurrentHost
        let spacing = SpacingWriter.wholeNumber(platform.preferences.value(forKey: IconSpacing.spacingKey, in: domain))
        let padding = SpacingWriter.wholeNumber(platform.preferences.value(forKey: IconSpacing.paddingKey, in: domain))
        recorder.measure("before", .object(["spacing": spacing.map { .number(Double($0)) } ?? .null,
                                            "padding": padding.map { .number(Double($0)) } ?? .null]))
        let small = IconSpacing.values(for: .small, custom: IconSpacingValues(spacing: 8, padding: 8)) ?? IconSpacingValues(spacing: 8, padding: 8)
        guard spacing != small.spacing || padding != small.padding else {
            recorder.fail("The icon spacing is Small already, so a change to it can't be measured. Set it to something else first.")
            return
        }
        recorder.measure("small", .object(["spacing": .number(Double(small.spacing)), "padding": .number(Double(small.padding))]))
        recorder.measure("testItemItems", .number(Double(count)))

        let beforeWidths = await measure(names, context)
        recorder.measure("widthsBefore", beforeWidths.json)

        // The change, and what it does.
        var wrote = false
        var cutShort = false
        var outcomes: [String] = []
        var afterWidths: Widths?
        do {
            do {
                try await context.defaults.writeAll([
                    DefaultsChange(key: IconSpacing.spacingKey, value: .integer(small.spacing)),
                    DefaultsChange(key: IconSpacing.paddingKey, value: .integer(small.padding)),
                ], in: domain, lifetime: .untilQuit)
            } catch let error as DefaultsAccessError {
                if case .keptByMantel = error {
                    throw ProbeRefusal(message: "Mantel keeps the icon spacing it was given in Settings, so this probe won't change it. Use Restore original spacing first.")
                }
                throw ProbeRefusal(message: error.localizedDescription)
            }
            wrote = true
            recorder.changeBegan()
            let relaunched = try await relaunch(candidate, names, context, recorder: &recorder)
            outcomes.append(relaunched.outcome)
            recorder.measure("itemsBackMs", ProbeJSON.number(relaunched.backMs))
            afterWidths = await measure(names, context)
        } catch is CancellationError {
            cutShort = true
            recorder.note("The probe was cut short; the icon spacing was put back.")
        } catch let refusal as ProbeRefusal {
            recorder.fail(refusal.message)
        } catch {
            recorder.fail("The icon spacing couldn't be changed: \(error.localizedDescription)")
        }

        if let afterWidths {
            recorder.measure("widthsAfter", afterWidths.json)
            recorder.measure("systemChanged", .bool(differs(beforeWidths.clocks, afterWidths.clocks)))
            let deltas = deltas(from: beforeWidths, to: afterWidths)
            recorder.measure("testItemWidthDeltas", .object(deltas.json))
            recorder.measure("smallestShrink", ProbeJSON.number(deltas.smallestShrink))
            if deltas.compared == 0 { recorder.note("No width of the test item could be compared before and after.") }
        }

        // Put back, whatever happened above.
        if wrote {
            var failures: [String] = []
            for key in [IconSpacing.spacingKey, IconSpacing.paddingKey] {
                do {
                    try await context.defaults.undo(key: key, in: domain)
                } catch {
                    failures.append("\(key): \(error.localizedDescription)")
                }
            }
            if failures.isEmpty {
                recorder.changeUndone()
            } else {
                recorder.undoFailed("The icon spacing couldn't be put back: \(failures.joined(separator: "; ")) Mantel puts it back when it next starts.")
            }
        }
        guard wrote, !cutShort else { return }

        // And the test item is opened again, to draw what is as it was.
        do {
            let again = try await relaunch(candidate, names, context, recorder: &recorder)
            outcomes.append(again.outcome)
        } catch {
            recorder.note("The probe was cut short; the test item wasn't opened again after the spacing was put back.")
            recorder.measure("relaunches", strings: outcomes)
            return
        }
        recorder.measure("relaunches", strings: outcomes)
        let restoredWidths = await measure(names, context)
        recorder.measure("widthsRestored", restoredWidths.json)
        recorder.measure("restoredWidthsMatch", .bool(matches(restoredWidths, beforeWidths)))
        recorder.note("The clock's own text can change its width by a few points between two readings, so systemChanged is only a hint.")
    }

    // MARK: Relaunching

    /// Asks the test item to quit and opens it again, and waits for its items. The outcome in words, and when all its items were back.
    private static func relaunch(_ candidate: RelaunchCandidate, _ names: [String], _ context: ProbeContext,
                                 recorder: inout ProbeRecorder) async throws -> (outcome: String, backMs: Double?) {
        // It is asked to quit as the process it is now, which is not the one it was when the probe began once it has been relaunched.
        let outcome = await context.platform.relauncher.relaunch(context.fixtureRelaunchCandidate(refreshing: candidate))
        let text: String
        switch outcome {
        case .relaunched: text = "relaunched"
        case .didNotQuit: text = "didNotQuit"
        case .couldNotOpen: text = "couldNotOpen"
        }
        if outcome != .relaunched { recorder.note("The test item didn't relaunch (\(text)); what is measured is the menu bar as it was.") }
        let waited = try await context.waitForFixtureItems(names, upTo: waitForItemsMs)
        if waited.allFoundMs == nil { recorder.note("Not every item of the test item was in the menu bar again within 5 s.") }
        return (text, waited.allFoundMs)
    }

    // MARK: Measuring

    private static func measure(_ names: [String], _ context: ProbeContext) async -> Widths {
        let platform = context.platform
        var widths = Widths()
        let layout = await context.layoutProvider()
        for display in layout.displays {
            var perItem: [String: CGFloat] = [:]
            for name in names {
                if let location = await platform.locator.locate(context.fixtureItemID(name), on: display.uuid, since: nil) {
                    perItem[name] = location.slotFrame.width
                }
            }
            widths.items[display.uuid] = perItem
        }
        let agent = await context.agentSnapshot()
        for window in agent.chosenWindows() {
            let slots = agent.agentWindows[window.index].slots
            if let clock = slots.first(where: { ($0.identifier ?? "").lowercased().hasSuffix("clock") }), let frame = clock.frame {
                widths.clocks[window.displayUUID] = frame.width
            }
        }
        return widths
    }

    private static func differs(_ before: [String: CGFloat], _ after: [String: CGFloat]) -> Bool {
        before.contains { display, width in after[display].map { abs($0 - width) > tolerance } ?? false }
    }

    /// What each item's slot is wider by now than it was: after minus before, for the items that have a width in both.
    private struct Deltas {
        var perDisplay: [String: [String: Double]] = [:]
        var compared = 0
        /// How much narrower the item that shrank the least is (negative when one grew): nil when none was compared.
        var smallestShrink: Double?

        var json: [String: JSONValue] {
            perDisplay.mapValues { items in .object(items.mapValues(JSONValue.number)) }
        }
    }

    private static func deltas(from before: Widths, to after: Widths) -> Deltas {
        var result = Deltas()
        for (display, items) in before.items {
            for (name, width) in items {
                guard let now = after.items[display]?[name] else { continue }
                let delta = Double(now - width)
                result.perDisplay[display, default: [:]][name] = delta
                result.compared += 1
                result.smallestShrink = min(result.smallestShrink ?? -delta, -delta)
            }
        }
        return result
    }

    /// Whether every width of the test item's that was measured before is within a point of it now, and some were measured. (The clock's
    /// width isn't compared: its text changes with the time.)
    private static func matches(_ now: Widths, _ before: Widths) -> Bool {
        var compared = 0
        for (display, items) in before.items {
            for (name, width) in items {
                guard let again = now.items[display]?[name], abs(again - width) <= tolerance else { return false }
                compared += 1
            }
        }
        return compared > 0
    }
}
