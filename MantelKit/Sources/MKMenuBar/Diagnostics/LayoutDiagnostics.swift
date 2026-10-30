import Foundation
import MKCore
import MKLayout

/// The Diagnostics rows about the order of the menu bar, the pictures of its icons and the space between them. They are worded here, for the
/// pane and the copied report alike, and say nothing of any app: no row names one.
public enum LayoutDiagnostics {
    /// The "Menu bar layout", "Icon images" and "Icon spacing" rows, in that order.
    ///
    /// - Parameters:
    ///   - layout: what the layout writer last said; nil before it has said anything.
    ///   - images: how many icons have a captured picture, when the last was captured, and whether Screen Recording is granted.
    ///   - spacing: what the two spacing keys hold now.
    ///   - spacingWorks: whether macOS applies the spacing on this Mac (`IconSpacing.macOSApplies`).
    ///   - timeZone: the zone the times are written in.
    public static func rows(layout: LayoutStatus?, images: (count: Int, last: Date?, screenRecording: Bool), spacing: SpacingState,
                            spacingWorks: Bool, timeZone: TimeZone = .current) -> [DiagnosticsCheck] {
        [layoutRow(layout, timeZone: timeZone), imagesRow(images, timeZone: timeZone), spacingRow(spacing, works: spacingWorks)]
    }

    /// How many icons have a picture, and when the newest was captured, from what the pictures' records say (one date for each picture an
    /// icon has).
    public static func imageSummary(captured: [[Date]]) -> (count: Int, last: Date?) {
        let withPictures = captured.filter { !$0.isEmpty }
        return (withPictures.count, withPictures.compactMap { $0.max() }.max())
    }

    // MARK: The rows

    static func layoutRow(_ status: LayoutStatus?, timeZone: TimeZone) -> DiagnosticsCheck {
        let title = "Menu bar layout"
        guard let status else { return DiagnosticsCheck(title: title, status: .unknown, detail: HidingDiagnostics.notReadYet) }
        switch status.availability {
        case .needsGrant:
            return DiagnosticsCheck(title: title, status: .warning, detail: "Grant access to reorder in Settings › Layout.")
        case .held(let reason):
            return DiagnosticsCheck(title: title, status: .warning, detail: reason)
        case .broken(let reason):
            return DiagnosticsCheck(title: title, status: .problem, detail: reason)
        case .available:
            break
        }
        // The time of an error is when the writer says it happened; a write that failed leaves the last report as it was.
        let failedAt = status.lastErrorAt.map { " (\(time($0, in: timeZone)))" } ?? ""
        switch status.lastError {
        case .notAccepted?:
            return DiagnosticsCheck(title: title, status: .problem, detail: "macOS didn't accept the last order\(failedAt).")
        case .failed(let text)?:
            return DiagnosticsCheck(title: title, status: .problem, detail: "Couldn't change the menu bar order\(failedAt): \(text)")
        case .broken(let reason)?:
            return DiagnosticsCheck(title: title, status: .problem, detail: reason)
        case .needsGrant?, nil:
            break
        }
        guard let report = status.lastReport else {
            return DiagnosticsCheck(title: title, status: .ok, detail: "Reordering works.")
        }
        // A write that placed nothing is not a reordering that works: the icons it was to place can't be, and the bar is as it was.
        if report.placed == 0, !report.unresolved.isEmpty || !report.notPlaced.isEmpty {
            let ownItems = report.notPlaced.contains { OwnItems.kind(name: $0, description: nil) != nil }
            return DiagnosticsCheck(title: title, status: .warning,
                                    detail: "The last change placed no icons (\(time(report.at, in: timeZone))). "
                                        + (ownItems ? LayoutCopy.notPlacedBanner : LayoutCopy.cantReorderCaption))
        }
        return DiagnosticsCheck(title: title, status: .ok,
                                detail: "Reordering works. Last change checked at \(time(report.at, in: timeZone)).")
    }

    static func imagesRow(_ images: (count: Int, last: Date?, screenRecording: Bool), timeZone: TimeZone) -> DiagnosticsCheck {
        let title = "Icon images"
        guard images.screenRecording else {
            return DiagnosticsCheck(title: title, status: .warning, detail: "Screen Recording is off, so app icons stand in.")
        }
        guard images.count > 0, let last = images.last else {
            return DiagnosticsCheck(title: title, status: .unknown, detail: "No icon pictures captured yet.")
        }
        let icons = images.count == 1 ? "1 icon" : "\(images.count) icons"
        return DiagnosticsCheck(title: title, status: .ok, detail: "\(icons) captured, the last at \(time(last, in: timeZone)).")
    }

    static func spacingRow(_ spacing: SpacingState, works: Bool) -> DiagnosticsCheck {
        let title = "Icon spacing"
        guard works else { return DiagnosticsCheck(title: title, status: .warning, detail: IconSpacing.notAppliedText) }
        return DiagnosticsCheck(title: title, status: .ok, detail: "\(spacing.preset.title).")
    }

    private static func time(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
