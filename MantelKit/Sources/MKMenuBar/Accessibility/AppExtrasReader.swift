import CoreGraphics
import Foundation
import MKCore
import Synchronization

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

/// The names the items of each process gave themselves, by position in the process's list, for the next read to fall back on.
///
/// An item that has a name of its own is told by it (`ItemID.identifier`); one that hasn't, by its place (`ItemID.index`), and the two
/// are different IDs, under which its picture and its place in the layout are kept. The read of an item's identifier can time out
/// (an app that is slow for a moment), and an item whose name wasn't read would then be taken for one without, and change IDs for a read
/// and back. So the name an item last gave is kept, and used for as long as the read of it keeps timing out. A read that answers
/// says what the item is called now, and a read that answers with no name remembers that it has none: a later read that doesn't come
/// says the same, and doesn't leave the name in doubt.
///
/// What is remembered is by position, so it is of use only while the list is the one it was kept from: an app that has dropped or added
/// an item has moved the others to other positions, and what was kept for a position is of another item. The length of the list is kept
/// with the names, and a read of a list of another length forgets them at its start: what is remembered after it is what it learned of
/// the list it saw, and a read that comes after it and doesn't learn a position again has nothing of another list to fall back on.
/// A list that keeps its length while its items change places (or one replaces another) is told by the element each position's answer
/// was kept for: the name or the "no name" stands only for the element that gave it, and an element that is at the position now and
/// isn't that one is another item, whose name is in doubt. That holds only for an app whose elements are seen to be the same from one
/// read to the next (`Known.handlesHold`: the same element twice at the same position): an app that makes new elements for each read
/// would have no name remembered at all, and an identifier that times out would make its read incomplete for good. Until an app has
/// shown that its elements hold, and for an app that never does, what is kept stands by position alone.
final class IdentifierMemory: Sendable {
    /// By process: the app it is, the names its items gave by position, and the positions whose items answered with none. A process ID
    /// that another app has taken over (the first has quit and the number is used again) has nothing remembered: the names are of the app
    /// that had it.
    private struct Known {
        var bundleID: String?
        var names: [Int: String]
        var nameless: Set<Int> = []
        /// The element that gave the answer kept for each position (a name, or "no name").
        var elements: [Int: AXElementRef] = [:]
        /// How many items the process's list had when the last read began: the list the names are of.
        var listLength: Int?
        /// Whether the process has given the same element twice at the same position: its elements can tell its items apart. It stays
        /// until a list of the same length keeps none of the kept elements (the app has begun to make new ones), and a list of another
        /// length forgets the elements, not this.
        var handlesHold = false

        /// Whether what is kept for `position` stands for `element`: always, until the process has shown that its elements hold, and then
        /// only for the element that gave it.
        func answers(to element: AXElementRef, at position: Int) -> Bool {
            !handlesHold || elements[position] == element
        }
    }

    private let processes = Mutex<[pid_t: Known]>([:])
    /// The apps whose elements were found not to be the same from one read to the next, which the log has said.
    private let reportedUnstable = Mutex<Set<String>>([])

    /// What `element`, the item at `position` in the list of the process `pid`, of the app `bundleID`, last called itself; nil when it
    /// isn't the element the position's name was kept for.
    func name(of element: AXElementRef, ofProcess pid: pid_t, bundleID: String?, at position: Int) -> String? {
        processes.withLock { processes in
            guard let process = processes[pid], process.bundleID == bundleID, process.answers(to: element, at: position) else { return nil }
            return process.names[position]
        }
    }

    /// Begins a read of the list of the process `pid`, of the app `bundleID`, whose items are `children`: when what is remembered of it
    /// is of a list of another length, the names and the "no name"s are forgotten, as they are of other items. The length is kept.
    ///
    /// Returns true the first time an app is found to give new elements for the same list: of the same length as the last read's, with
    /// none of the elements that read kept (a list whose items only trade places keeps them all), when its elements weren't holding then;
    /// an app whose elements had held goes back to positions at such a read, and is said at the next one.
    /// The caller says so in the log, so that it is known why the app's names are kept by position.
    func begin(listOf children: [AXElementRef], ofProcess pid: pid_t, bundleID: String?) -> Bool {
        let length = children.count
        let unstable = processes.withLock { processes -> Bool in
            var process = processes[pid].flatMap { $0.bundleID == bundleID ? $0 : nil } ?? Known(bundleID: bundleID, names: [:])
            defer { processes[pid] = process }
            if process.listLength != length {
                process.names = [:]
                process.nameless = []
                process.elements = [:]
                process.listLength = length
                return false
            }
            guard !process.elements.isEmpty, !children.contains(where: { process.elements.values.contains($0) }) else { return false }
            // None of the kept elements is in a list of the same length: the app makes new ones. An app whose elements had held goes back to
            // positions until one is seen twice again (a swap keeps every element, so this costs the swap check nothing), and is said at the
            // second such read in a row; one that never held is said at the first.
            defer { process.handlesHold = false }
            return !process.handlesHold
        }
        guard unstable, let bundleID else { return false }
        return reportedUnstable.withLock { $0.insert(bundleID).inserted }
    }

    /// Whether `element`, the item at `position` in the list of the process `pid`, of the app `bundleID`, last answered that it has no
    /// name; false when it isn't the element the position's answer was kept for.
    func isNameless(_ element: AXElementRef, ofProcess pid: pid_t, bundleID: String?, at position: Int) -> Bool {
        processes.withLock { processes in
            guard let process = processes[pid], process.bundleID == bundleID, process.answers(to: element, at: position) else { return false }
            return process.nameless.contains(position)
        }
    }

    /// Keeps `name` for `element`, the item at `position`; when it has none, forgets the name that was kept for the position and keeps
    /// that the item has none.
    func remember(_ name: String?, of element: AXElementRef, ofProcess pid: pid_t, bundleID: String?, at position: Int) {
        processes.withLock { processes in
            var process = processes[pid].flatMap { $0.bundleID == bundleID ? $0 : nil } ?? Known(bundleID: bundleID, names: [:])
            process.names[position] = name
            if process.elements[position] == element { process.handlesHold = true }
            process.elements[position] = element
            if name == nil { process.nameless.insert(position) } else { process.nameless.remove(position) }
            processes[pid] = process
        }
    }

    /// Forgets the processes that aren't in `pids`, which are no longer running.
    func keep(only pids: Set<pid_t>) {
        processes.withLock { processes in processes = processes.filter { pids.contains($0.key) } }
    }
}

/// Asks an app for its status items: the children of its `AXExtrasMenuBar`, each with its frame, identifier, title and description.
///
/// It is shared by the menu bar reader and by the scanner. The calls block, so callers run it off the main actor. A copy of a reader
/// shares what it remembers (`IdentifierMemory`) with the one it was copied from.
struct AppExtrasReader: Sendable {
    /// How many reads of an app's items may time out in one read before the app counts as having timed out. The reading stops
    /// there: an app that doesn't answer would otherwise cost every one of its items a wait of its own.
    static let itemTimeoutsForAppTimeout = 3

    let ax: any AXReading
    /// What the items last called themselves, for a read of the name that times out.
    let names = IdentifierMemory()

    func read(_ app: RunningApp) -> ExtrasOutcome {
        readWithElements(app).outcome
    }

    /// The same, with the element of each item the app lists, by the item's place in the list (`ExtraItem.index`): what a press or a
    /// menu is asked of. Empty unless the app answered.
    func readWithElements(_ app: RunningApp) -> (outcome: ExtrasOutcome, elements: [AXElementRef]) {
        let root = ax.application(pid: app.pid)
        do {
            guard case .elements(let bars) = try ax.attribute(AXName.extrasMenuBar, of: root), let bar = bars.first else {
                return (.noExtras, [])
            }
            let children = try ax.children(of: bar)
            guard !children.isEmpty else { return (.noExtras, []) }
            return (.items(readItems(of: app, children: children)), children)
        } catch {
            switch error {
            case .timeout: return (.timedOut, [])
            case .notTrusted: return (.notTrusted, [])
            case .noValue, .failure: return (.noExtras, [])
            }
        }
    }

    /// The items, in the order the app lists them. A read that times out leaves the item without that value, which is counted and
    /// not left unsaid. At the third timeout the reading stops, and the item it stopped in is left out: the items before it are
    /// whole. Whatever stops the reading before the last child (the timeouts, or a budget or a deadline that `PatientAX` ends the asking
    /// with, which the reader sees as timeouts) is `AppExtras.listCut`.
    private func readItems(of app: RunningApp, children: [AXElementRef]) -> AppExtras {
        let limit = Self.itemTimeoutsForAppTimeout
        if names.begin(listOf: children, ofProcess: app.pid, bundleID: app.bundleID), let bundleID = app.bundleID {
            Log.info("session", Self.unstableElementsLine(app: bundleID))
        }
        var timeouts = 0
        var items: [ExtraItem] = []
        var namesIncomplete = false
        for (index, child) in children.enumerated() {
            let frame = frame(of: child, timeouts: &timeouts)
            if timeouts >= limit { break }
            var identifier: String?
            switch identifierRead(of: child, timeouts: &timeouts) {
            case .named(let name):
                identifier = name
                names.remember(name, of: child, ofProcess: app.pid, bundleID: app.bundleID, at: index)
            case .nameless:
                names.remember(nil, of: child, ofProcess: app.pid, bundleID: app.bundleID, at: index)
            case .notRead:
                // The read of the name didn't come: the item is called what it was called, or has no name if it was seen to have none. What is
                // remembered is of a list as long as this one (`begin`), and, for an app whose elements hold, of this element: an item that went
                // or came moves the others to other positions, and items that trade places in a list of the same length leave other elements
                // at them.
                identifier = names.name(of: child, ofProcess: app.pid, bundleID: app.bundleID, at: index)
                if identifier == nil && !names.isNameless(child, ofProcess: app.pid, bundleID: app.bundleID, at: index) { namesIncomplete = true }
            }
            if timeouts >= limit { break }
            let title = string(AXName.title, of: child, timeouts: &timeouts)
            if timeouts >= limit { break }
            let description = string(AXName.description, of: child, timeouts: &timeouts)
            items.append(ExtraItem(index: index, frame: frame, identifier: identifier, title: title, description: description))
            if timeouts >= limit { break }
        }
        let listCut = items.count < children.count
        return AppExtras(pid: app.pid, bundleID: app.bundleID, name: app.name, items: items, timedOut: timeouts >= limit,
                         itemTimeouts: timeouts, namesIncomplete: namesIncomplete, listCut: listCut)
    }

    /// What the log says the first time an app is found to give new elements for its items at each read: its bundle ID. What an item last
    /// called itself is then kept by position alone, as it is for an app that hasn't shown its elements to hold.
    static func unstableElementsLine(app: String) -> String {
        "status items of \(app) are new elements at each read: their names are kept by position"
    }

    /// What the read of an item's identifier came to.
    private enum IdentifierRead {
        /// The item gave a name.
        case named(String)
        /// The item answered that it has none.
        case nameless
        /// The read didn't come: it timed out, or failed with an error that isn't "no value" (an element that went mid-read).
        case notRead
    }

    /// `kAXErrorInvalidUIElement`: the element went while it was read.
    static let elementGone: Int32 = -25202

    private func identifierRead(of element: AXElementRef, timeouts: inout Int) -> IdentifierRead {
        do {
            guard case .string(let value) = try ax.attribute(AXName.identifier, of: element), !value.isEmpty else { return .nameless }
            return .named(value)
        } catch {
            switch error {
            case .noValue: return .nameless
            case .timeout:
                timeouts += 1
                return .notRead
            // An element that went while it was read, or no grant: what its name is isn't known.
            case .notTrusted, .failure(Self.elementGone): return .notRead
            // Any other error is the app's answer that the item has no name.
            case .failure: return .nameless
            }
        }
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
