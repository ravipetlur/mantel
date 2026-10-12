import CoreGraphics
import Foundation
import MKCore

/// What asking one app for its status items came to.
enum ExtrasOutcome: Sendable, Equatable {
    /// The app listed its items. When too many reads of them timed out (`AppExtras.timedOut`), the list ends where the reading
    /// stopped.
    case items(AppExtras)
    /// The app answered and has no extras menu bar, or an empty one.
    case noExtras
    /// The app didn't answer in time.
    case timedOut
    /// Accessibility isn't granted to Mantel.
    case notTrusted
}

/// Asks an app for its status items: the children of its `AXExtrasMenuBar`, each with its frame, identifier, title and description.
///
/// It is shared by the reader the probes use and by the scanner. The calls block, so callers run it off the main actor.
struct AppExtrasReader: Sendable {
    /// How many reads of an app's items may time out in one read before the app counts as having timed out. The reading stops
    /// there: an app that doesn't answer would otherwise cost every one of its items a wait of its own.
    static let itemTimeoutsForAppTimeout = 3

    let ax: any AXReading

    func read(_ app: RunningApp) -> ExtrasOutcome {
        let root = ax.application(pid: app.pid)
        do {
            guard case .elements(let bars) = try ax.attribute(AXName.extrasMenuBar, of: root), let bar = bars.first else {
                return .noExtras
            }
            let children = try ax.children(of: bar)
            guard !children.isEmpty else { return .noExtras }
            return .items(readItems(of: app, children: children))
        } catch {
            switch error {
            case .timeout: return .timedOut
            case .notTrusted: return .notTrusted
            case .noValue, .failure: return .noExtras
            }
        }
    }

    /// The items, in the order the app lists them. A read that times out leaves the item without that value, which is counted and
    /// not left unsaid. At the third timeout the reading stops, and the item it stopped in is left out: the items before it are
    /// whole.
    private func readItems(of app: RunningApp, children: [AXElementRef]) -> AppExtras {
        let limit = Self.itemTimeoutsForAppTimeout
        var timeouts = 0
        var items: [ExtraItem] = []
        for (index, child) in children.enumerated() {
            let frame = frame(of: child, timeouts: &timeouts)
            if timeouts >= limit { break }
            let identifier = string(AXName.identifier, of: child, timeouts: &timeouts)
            if timeouts >= limit { break }
            let title = string(AXName.title, of: child, timeouts: &timeouts)
            if timeouts >= limit { break }
            let description = string(AXName.description, of: child, timeouts: &timeouts)
            items.append(ExtraItem(index: index, frame: frame, identifier: identifier, title: title, description: description))
            if timeouts >= limit { break }
        }
        return AppExtras(pid: app.pid, bundleID: app.bundleID, name: app.name, items: items, timedOut: timeouts >= limit,
                         itemTimeouts: timeouts)
    }

    // MARK: Attributes

    /// The text of the attribute; nil when it has none, or when the app didn't answer in time, which is counted in `timeouts`.
    private func string(_ name: String, of element: AXElementRef, timeouts: inout Int) -> String? {
        guard case .string(let value)? = value(name, of: element, timeouts: &timeouts), !value.isEmpty else { return nil }
        return value
    }

    /// The element's frame from its position and size; nil when either is missing or didn't come in time (counted).
    private func frame(of element: AXElementRef, timeouts: inout Int) -> CGRect? {
        guard case .point(let origin)? = value(AXName.position, of: element, timeouts: &timeouts),
              case .size(let size)? = value(AXName.size, of: element, timeouts: &timeouts) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func value(_ name: String, of element: AXElementRef, timeouts: inout Int) -> AXValueBox? {
        do {
            return try ax.attribute(name, of: element)
        } catch {
            if error == .timeout { timeouts += 1 }
            return nil
        }
    }
}
