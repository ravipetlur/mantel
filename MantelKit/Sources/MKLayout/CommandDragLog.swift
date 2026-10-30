import Foundation

/// What the log says of a ⌘-drag, in its words: bundle IDs, section names and seconds, never an icon's name.
///
/// Two lines a drag: one when it is seen to begin (whether everything was shown for it, or why not), and one when its follow ends (the
/// sections that changed, or why nothing was followed, with the time from the drop).
public enum CommandDragLog {
    /// Whether everything is shown on the bar for a drag, and if not why.
    public enum ShowAll: Sendable, Equatable {
        case shown
        case settingOff
        /// Everything is showing already, or Focus Mode is: the drag has no reveal of its own to put away.
        case somethingShowing
        /// An earlier drag's reveal is still in force.
        case earlierDragShowing

        /// What is decided at the mouse-down: the setting and whether the reveal lets the drag show everything (`settingOn`,
        /// `revealAllows`), and whether an earlier drag's reveal is still out (`earlierDragShowing`).
        public static func decide(settingOn: Bool, revealAllows: Bool, earlierDragShowing: Bool) -> ShowAll {
            if !settingOn { return .settingOff }
            if !revealAllows { return .somethingShowing }
            if earlierDragShowing { return .earlierDragShowing }
            return .shown
        }
    }

    /// How a ⌘-drag ended, as the monitor saw it.
    public enum End: Sendable, Equatable {
        /// The mouse went up.
        case mouseUp
        /// No mouse-up was seen: the drag was taken as ended when it had lasted this long (`CommandDragReveal.cap`).
        case capReached(after: TimeInterval)
    }

    /// How a ⌘-drag's follow ended.
    public enum Follow: Sendable, Equatable {
        /// The read was followed and these apps are in other sections now (by bundle ID).
        case moved([String: MenuBarSection])
        /// The read was followed and no app changed its section.
        case nothingMoved
        /// The read wasn't trusted (`FollowTrust`).
        case notTrusted(FollowTrust.Doubt)
        /// A write of the order was pending or settling: the follow is taken when it ends.
        case writeUnderWay
        /// The read had no bar in it.
        case noBars
        /// Nothing was followed: Mantel was quitting or resetting, or no read came back.
        case notRun
    }

    /// The line for a drag that began. `toldAfter` is the time from the mouse-down (as the monitor saw it) to when the session was told:
    /// more than a moment when the session was busy with earlier work, and then the line says so, since its own time is the later one.
    public static func beganLine(_ showAll: ShowAll, toldAfter: TimeInterval = 0) -> String {
        let line = switch showAll {
        case .shown: "⌘-drag seen: began; everything shown for it"
        case .settingOff: "⌘-drag seen: began; everything not shown for it (the setting is off)"
        case .somethingShowing: "⌘-drag seen: began; everything not shown for it (everything or Focus Mode was showing already)"
        case .earlierDragShowing: "⌘-drag seen: began; everything not shown for it (an earlier drag's reveal was still in force)"
        }
        return toldAfter >= 1 ? "\(line); told \(seconds(toldAfter)) after it was seen" : line
    }

    /// The line for the end of a follow. `afterDrop` is the time from the mouse-up (as the monitor saw it) to now, `begunAfter` the time
    /// from the mouse-up to when the session began the follow's own wait (more than a moment when the session was busy with earlier
    /// work), and `limitReached` whether the follow stopped reading because `LayoutFollower.commandDragFollowLimit` had passed. A drag
    /// that `end`ed with no mouse-up seen has no drop: the time counts from when it was taken as ended, and the line says that.
    public static func followLine(_ follow: Follow, afterDrop: TimeInterval, begunAfter: TimeInterval, limitReached: Bool,
                                  end: End = .mouseUp) -> String {
        let moment: String
        let missed: String
        switch end {
        case .mouseUp:
            moment = "the drop"
            missed = ""
        case .capReached(let held):
            moment = "the cap"
            missed = "; no mouse-up seen, the drag was held \(seconds(held))"
        }
        let late = begunAfter >= 1 ? "; its wait began \(seconds(begunAfter)) after \(moment)" : ""
        let limit = limitReached ? "; the limit of \(seconds(LayoutFollower.commandDragFollowLimit)) was reached" : ""
        let time = "\(seconds(afterDrop)) after \(moment)"
        switch follow {
        case .moved(let moves):
            let list = moves.sorted { $0.key < $1.key }.map { "\($0.key) to \($0.value.title)" }.joined(separator: ", ")
            return "⌘-drag followed \(time): sections changed: \(list)\(late)\(missed)"
        case .nothingMoved:
            return "⌘-drag followed \(time): no section changed\(late)\(missed)"
        case .notTrusted(let doubt):
            return "⌘-drag not followed \(time): \(words(doubt))\(limit)\(late)\(missed)"
        case .writeUnderWay:
            return "⌘-drag not followed \(time): a write of the order was under way; it is followed when the write ends\(late)\(missed)"
        case .noBars:
            return "⌘-drag not followed \(time): the read had no bars\(limit)\(late)\(missed)"
        case .notRun:
            return "⌘-drag not followed \(time): quitting, resetting or no read taken\(late)\(missed)"
        }
    }

    private static func words(_ doubt: FollowTrust.Doubt) -> String {
        switch doubt {
        case .appsMissing(let apps): "a read not trusted: \(apps.joined(separator: ", ")) didn't answer, or answered in part"
        case .agentReadCut: "a read not trusted: MenuBarAgent's read was cut"
        case .unclaimedSlots(let count): "a read not trusted: \(count) slots that no app claims"
        }
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f s", value)
    }

    private static func seconds(_ value: Duration) -> String {
        seconds(Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18)
    }
}
