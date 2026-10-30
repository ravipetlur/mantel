import Foundation

/// When a group's panel opens and closes for the pointer: it opens when the pointer has rested on the group's icon for `openDelay`, and
/// closes when the pointer has been off both the icon and the panel for `closeDelay`. Pure: it takes where the pointer is with the time,
/// and says what to do. Only a group that opens on hover is told of (the caller leaves the others out: `onGroup` is nil for them).
///
/// - **A panel the person opened by a click** isn't this machine's: it closes no panel it didn't open. A click on the icon while the
///   pointer rests there (`iconClicked`, `panelOpenedElsewhere`) spends the rest, so the panel it opens isn't taken for the hover's; and
///   one that the app didn't open after all (it was open already, or the group has nothing to list) is told back (`declined`), so the
///   machine doesn't close what it never opened. A click that closes a panel while the pointer rests on the icon doesn't open it again
///   until the pointer has left (`panelClosed`).
/// - **A click on the icon of a panel this machine opened** takes the panel over (`iconClicked`): it is the person's from then on, and the
///   hover no longer closes it.
/// - **Another group's icon** under the pointer while a panel is open: the open one's close time runs, and the new one opens after its own
///   delay, which closes the old one.
public struct GroupHover: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        /// Where the pointer is: on a hover group's icon, on the open panel, or neither, at this time.
        case pointer(onGroup: GroupID?, onPanel: Bool, at: Date)
        case tick(Date)
    }

    public enum Effect: Sendable, Equatable {
        case open(GroupID)
        /// Close the panel of this group (the one the machine opened): not whichever panel is open.
        case close(GroupID)
    }

    /// What a click on a group's icon comes to.
    public enum IconClick: Sendable, Equatable {
        /// The panel is the hover's: make it key (the hover gives it up) instead of closing it.
        case makeKey
        /// The click is the person's alone: open the panel or close it as it stands.
        case toggle
    }

    /// The group of the hover whose icon the pointer is on: the group a spot names (`EmptySpace.ownSlots` gives an own item's layout ID),
    /// when it is one that opens on hover. Nil for anywhere else, and for a group icon a read could only tell by its description.
    public static func group(under spot: EmptySpace.Spot, among hoverGroups: Set<GroupID>) -> GroupID? {
        guard case .ownItem(let item) = spot, let group = OwnItems.groupID(of: item), hoverGroups.contains(group) else { return nil }
        return group
    }

    public static let openDelay: Duration = .milliseconds(300)
    public static let closeDelay: Duration = .milliseconds(500)

    /// The group the pointer rests on, since when, and whether that rest has already had its say (it opened the panel, or the panel was
    /// closed while the pointer was there).
    private struct Rest: Equatable {
        let group: GroupID
        let since: Date
        var spent: Bool
    }

    private var resting: Rest?
    /// The group whose panel this machine opened, and since when the pointer has been off both it and the panel.
    private var opened: GroupID?
    private var awaySince: Date?

    public init() {}

    /// Whether time matters now: the pointer rests on an icon, or a panel it opened is open. The caller samples while this is so.
    public var isActive: Bool { resting != nil || opened != nil }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .pointer(let onGroup, let onPanel, let at):
            pointer(onGroup: onGroup, onPanel: onPanel, at: at)
            return []
        case .tick(let now):
            return tick(now)
        }
    }

    /// A group's panel closed, whatever closed it: when it is the one this machine opened, the machine no longer has one open, and a rest
    /// that is still going on doesn't open it again. (Another group's panel closing, as one opens in its place, is no concern of it.)
    public mutating func panelClosed(_ group: GroupID) {
        guard opened == group else { return }
        opened = nil
        awaySince = nil
        resting?.spent = true
    }

    /// The app didn't open the panel an `.open(group)` asked for (it was open already, or the group has nothing to list): the machine
    /// doesn't hold it open, and the rest is spent, so nothing opens again until the pointer has left and come back.
    public mutating func declined(_ group: GroupID) {
        if opened == group {
            opened = nil
            awaySince = nil
        }
        if resting?.group == group { resting?.spent = true }
    }

    /// A panel of this group was opened by something else (a click) while the pointer may rest on its icon: that rest has had its say.
    public mutating func panelOpenedElsewhere(_ group: GroupID) {
        if resting?.group == group { resting?.spent = true }
    }

    /// The person clicked the group's icon. A panel this machine opened is theirs from now on (`.makeKey`: the click takes it over rather
    /// than closing it); for any other the rest is spent and the click opens or closes as usual (`.toggle`).
    public mutating func iconClicked(_ group: GroupID) -> IconClick {
        if opened == group {
            opened = nil
            awaySince = nil
            resting?.spent = true
            return .makeKey
        }
        panelOpenedElsewhere(group)
        return .toggle
    }

    private mutating func pointer(onGroup: GroupID?, onPanel: Bool, at: Date) {
        if let group = onGroup {
            if resting?.group != group { resting = Rest(group: group, since: at, spent: false) }
        } else {
            resting = nil
        }
        // The panel stays while the pointer is on its own icon or on it.
        let onOpen = onPanel || (onGroup != nil && onGroup == opened)
        if opened != nil, !onOpen {
            if awaySince == nil { awaySince = at }
        } else {
            awaySince = nil
        }
        if let group = onGroup, group == opened { resting?.spent = true }
    }

    private mutating func tick(_ now: Date) -> [Effect] {
        var effects: [Effect] = []
        if let group = opened, let away = awaySince, now.timeIntervalSince(away) >= Self.seconds(Self.closeDelay) {
            effects.append(.close(group))
            opened = nil
            awaySince = nil
        }
        if let rest = resting, !rest.spent, now.timeIntervalSince(rest.since) >= Self.seconds(Self.openDelay) {
            effects.append(.open(rest.group))
            opened = rest.group
            awaySince = nil
            resting?.spent = true
        }
        return effects
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
