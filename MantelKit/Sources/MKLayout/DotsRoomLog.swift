import CoreGraphics
import Foundation

/// Which kind of display a bar is on, as the log names it.
public enum DisplayKind: Sendable, Equatable {
    case builtIn, other

    /// "the built-in display" or "another display": what follows "on" in a line of the log.
    public var phrase: String {
        switch self {
        case .builtIn: "the built-in display"
        case .other: "another display"
        }
    }
}

/// What the log says about Mantel's dots and the « menu, for the owner's daily use: counts, kinds of display and bundle IDs, never a
/// window title or what an icon says. The lines are made here, so that what is said (and how often) can be tested.
public struct DotsRoomLog: Sendable, Equatable {
    /// What has been said: the log says each of these once for as long as Mantel runs, though it can come up on every read.
    private var said: Set<String> = []
    /// By display: what was held in Hidden for the dots, and when, at the last stop of the moves that was said.
    private var stopsSaid: [String: StopSaid] = [:]

    private struct StopSaid: Sendable, Equatable {
        var held: CGFloat
        var at: Date
    }

    /// A stop of the moves for the dots is said again for the same display only when what is held for the dots there has changed, or when
    /// this long has gone by: a trap that comes back and is stopped again, cycle after cycle, is one thing, said now and then.
    public static let stopRepeatAfter: TimeInterval = 10 * 60

    public init() {}

    // MARK: The lines

    /// Where the dots are, in a line of the log: in the « menu, or (when that is only told by where they say they are, as macOS 27 shows
    /// no « menu) behind the notch or the menus; on a display with no notch, under the menus.
    private static func place(inferred: Bool, notch: Bool = true) -> String {
        guard inferred else { return "in the « menu" }
        return notch ? "behind the notch or the menus" : "under the menus"
    }

    public static func moved(_ bundleID: String, kind: DisplayKind, inferred: Bool = false, pinned: Bool = false, notch: Bool = true) -> String {
        "Mantel's dots were \(place(inferred: inferred, notch: notch)) on \(kind.phrase); moved \(bundleID) to Hidden to make room"
            + (pinned ? "; it came back once, so it stays in Hidden until the displays change or half an hour has gone by" : "")
    }

    public static func roomIsBack(_ bundleID: String, kind: DisplayKind) -> String {
        "room is back on \(kind.phrase); \(bundleID) is in Shown again"
    }

    public static func cantTell(kind: DisplayKind, reason: DotsRoom.CantTell) -> String {
        switch reason {
        case .ownIconsShareAFrame, .dotHasNoSlot:
            "Mantel's dot has no place on \(kind.phrase)'s bar (\(reason.reason))"
        case .noOwnIcons, .ownIconsNotPlaced:
            "the « menu is showing on \(kind.phrase) but Mantel can't tell what is in it (\(reason.reason))"
        }
    }

    /// An app on trial that had been moved for the dots, and with which they are out of the way again.
    public static func pushedOutAgain(_ bundleID: String, kind: DisplayKind) -> String {
        "Mantel's dots were pushed out again on \(kind.phrase) with \(bundleID) back in Shown; it goes back to Hidden and stays there until the displays change or half an hour has gone by"
    }

    /// An app on trial that had been moved for another reason (it overflowed itself), and with which the dots are out of the way.
    public static func pushedOutByATrial(_ bundleID: String, kind: DisplayKind) -> String {
        "Mantel's dots were pushed out on \(kind.phrase) when \(bundleID) came back to Shown; it goes back to Hidden and stays there until the displays change or half an hour has gone by"
    }

    public static func nothingLeftToMove(kind: DisplayKind, inferred: Bool = false, notch: Bool = true) -> String {
        "Mantel's dots are \(place(inferred: inferred, notch: notch)) on \(kind.phrase), and no Shown app is left to move to Hidden to make room"
    }

    public static func automaticOverflowIsOff(kind: DisplayKind, inferred: Bool = false, notch: Bool = true) -> String {
        "Mantel's dots are \(place(inferred: inferred, notch: notch)) on \(kind.phrase); \"Move icons that don't fit to Hidden\" is off, so no app was moved"
    }

    public static let stillTheSamePlace = "Mantel's dots still report the same place after making room; Mantel stopped moving apps for them"

    public static func stillOutOfTheWay(kind: DisplayKind) -> String {
        "Mantel's dots are still out of the way on \(kind.phrase) after the apps that were moved for them; Mantel stopped moving apps for them"
    }

    public static func spacerIsInForce(kind: DisplayKind, inferred: Bool = false, notch: Bool = true) -> String {
        "Mantel's dots are \(place(inferred: inferred, notch: notch)) on \(kind.phrase), and the wide spacer is hiding icons, so no app was moved to make room"
    }

    // MARK: What a read comes to

    /// The lines the log says for a read of the menu bar.
    ///
    /// - What happened to apps is said every time it happens: a move for the dots, an app back in Shown, a trial that pushed the dots
    ///   out again, and a stop of the moves for the dots. (The tracker tells of a stop when it starts, and a stop that is over and starts
    ///   again is a new one. It is said again for a display only when what is held in Hidden for the dots there has changed, or after
    ///   `stopRepeatAfter`: a trap that keeps coming back says it now and then, and not every cycle.)
    /// - What is a state of the bar is said once for as long as Mantel runs, though every read finds it again: that the « menu is
    ///   showing and what is in it can't be told, that no Shown app is left to move, and (while automatic overflow is off, or the wide
    ///   spacer is in force) that a dot is out of the way and nothing is moved for it.
    ///
    /// - Parameters:
    ///   - verdict: what the read says of the dots on the bars that are shown.
    ///   - outcome: what the tracker did with the read; nil when it wasn't asked (automatic overflow is off, or the bar isn't collapsed).
    ///   - underTheSpacer: the wide spacer is the engine in force, so the dots are not made room for: where they sit is the spacer's doing.
    ///   - kind: the kind of display a display (`DisplayInfo.uuid`) is.
    ///   - hasNotch: whether it has a notch, which the wording of where the dots are depends on.
    ///   - now: the time of the read, which says how long ago a stop was said.
    public mutating func lines(verdict: DotsRoom.Verdict, outcome: AutoOverflowTracker.Outcome?, automaticOverflowIsOn: Bool,
                               underTheSpacer: Bool = false, now: Date = Date(timeIntervalSinceReferenceDate: 0),
                               kind: (String) -> DisplayKind, hasNotch: (String) -> Bool = { _ in true }) -> [String] {
        var lines: [String] = []
        func add(_ line: String) { lines.append(line) }
        func addOnce(_ line: String) { if said.insert(line).inserted { lines.append(line) } }

        for (display, reason) in verdict.cantTell.sorted(by: { $0.key < $1.key }) {
            addOnce(Self.cantTell(kind: kind(display), reason: reason))
        }
        if !automaticOverflowIsOn {
            for display in verdict.trapped {
                addOnce(Self.automaticOverflowIsOff(kind: kind(display), inferred: verdict.inferred.contains(display), notch: hasNotch(display)))
            }
        } else if underTheSpacer {
            for display in verdict.trapped {
                addOnce(Self.spacerIsInForce(kind: kind(display), inferred: verdict.inferred.contains(display), notch: hasNotch(display)))
            }
        }
        guard let outcome else { return lines }
        for move in outcome.movedForDots {
            add(Self.moved(move.bundleID, kind: kind(move.displayUUID), inferred: move.isInferred, pinned: move.isPinned,
                           notch: hasNotch(move.displayUUID)))
        }
        for move in outcome.returnedForDots { add(Self.roomIsBack(move.bundleID, kind: kind(move.displayUUID))) }
        for move in outcome.failedForDots {
            add(move.wasMovedForTheDots ? Self.pushedOutAgain(move.bundleID, kind: kind(move.displayUUID))
                : Self.pushedOutByATrial(move.bundleID, kind: kind(move.displayUUID)))
        }
        for stop in outcome.stoppedForDots {
            if let before = stopsSaid[stop.displayUUID], before.held == stop.held, now.timeIntervalSince(before.at) < Self.stopRepeatAfter {
                continue
            }
            stopsSaid[stop.displayUUID] = StopSaid(held: stop.held, at: now)
            add(stop.reason == .samePlace ? Self.stillTheSamePlace : Self.stillOutOfTheWay(kind: kind(stop.displayUUID)))
        }
        for display in outcome.noRoomToMakeFor {
            addOnce(Self.nothingLeftToMove(kind: kind(display), inferred: verdict.inferred.contains(display), notch: hasNotch(display)))
        }
        return lines
    }
}
