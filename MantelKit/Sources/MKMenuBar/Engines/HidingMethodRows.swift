import Foundation
import MKCore

/// One way of hiding, as Settings › Advanced offers it: a radio button with its title and a line under it.
public struct HidingMethodRow: Sendable, Equatable, Identifiable {
    public let choice: HidingMethodChoice
    public let title: String
    /// What the way does. For one that can't be used now it ends with why.
    public let caption: String
    /// Whether the person can choose it.
    public let isEnabled: Bool

    public var id: HidingMethodChoice { choice }

    /// The same choice, which can't be chosen.
    func disabled() -> HidingMethodRow {
        HidingMethodRow(choice: choice, title: title, caption: caption, isEnabled: false)
    }

    public init(choice: HidingMethodChoice, title: String, caption: String, isEnabled: Bool) {
        self.choice = choice
        self.title = title
        self.caption = caption
        self.isEnabled = isEnabled
    }
}

/// What Settings › Advanced shows of how icons are hidden: the choices, the line under them, and whether a switch is under way.
public struct HidingMethodPresentation: Sendable, Equatable {
    /// The choices. While a switch is under way none of them can be chosen.
    public let rows: [HidingMethodRow]
    /// "Now using: …", from the engine's own words; nil before the engine is known. It is there while a switch is under way too (the
    /// line it replaces, so that the pane can keep the room of the longer of the two).
    public let nowUsing: String?
    /// "Switching to …", while a switch is under way; nil otherwise.
    public let switching: String?

    /// Whether a switch is under way: the choice has moved, and the engine hasn't settled for it yet.
    public var isSwitching: Bool { switching != nil }

    public init(rows: [HidingMethodRow], nowUsing: String?, switching: String?) {
        self.rows = rows
        self.nowUsing = nowUsing
        self.switching = switching
    }
}

/// What Settings › Advanced says about how icons are hidden.
public enum HidingMethodRows {
    public static let automaticCaption = "Uses macOS's allowlist, and falls back by itself if that stops working."
    public static let switchesCaption = "Turns apps' switches off in System Settings › Menu Bar. Slower, but system indicators stay visible."
    /// What "Now using" adds when the wide spacer is the engine in use: how it hides, and what the person does to get icons hidden.
    public static let spacerNote = "It hides only the icons left of Mantel's divider, the thin line that shows while icons are revealed. ⌘-drag icons to its left."

    /// The ways Advanced offers, in order. The wide spacer isn't one of them: it is only what Automatic falls back to when neither the
    /// allowlist nor the switches can be used, and "Now using" then says how it works (`spacerNote`).
    ///
    /// - **Automatic** is never disabled: it is the one that falls back by itself.
    /// - **System Settings switches** is disabled while its engine can't be used (`unavailableReasons`), and the caption then ends
    ///   with the reason, as a sentence. A way never silently stands in for one that can't be used.
    /// - **An engine that failed out is not disabled.** Three failures in a row say nothing about whether it can be used: "Now using"
    ///   says why another is in use, and Refresh tries it again.
    /// - A way the status says nothing about (no status yet, or an engine that wasn't asked) is not an error: it can be chosen.
    public static func rows(engine: EngineStatus?) -> [HidingMethodRow] {
        [
            HidingMethodRow(choice: .automatic, title: "Automatic", caption: automaticCaption, isEnabled: true),
            row(.systemSettingsSwitches, kind: .approvals, caption: switchesCaption, engine: engine),
        ]
    }

    /// What the pane shows for the method the person has chosen and the engine as the session last said.
    ///
    /// - **A switch is under way** from the moment the choice moves until the engine has settled for it (`EngineStatus.decidedFor` is
    ///   the choice): the radio selection moves at once, the line reads "Switching to <the choice's title>…", and no choice can be made.
    ///   A status that doesn't say what it was chosen for says nothing is under way: that is the status before the first choice, and the one
    ///   after a reset has taken everything down (`HidingController.tearDown` forgets it), and a spinner that waits for a choice that
    ///   isn't coming would stay for good.
    /// - **When the engine has settled on something other than the choice** (the switches can't be used, say, so Mantel uses the
    ///   allowlist), the choices are open again and the line says why, as it always has: `EngineStatus.reason`.
    public static func presentation(method: HidingMethodChoice, engine: EngineStatus?) -> HidingMethodPresentation {
        let isSwitching = engine.map { switchIsUnderWay(method: method, engine: $0) } ?? false
        var rows = rows(engine: engine)
        if isSwitching { rows = rows.map { $0.disabled() } }
        let title = rows.first { $0.choice == method }?.title ?? method.rawValue
        return HidingMethodPresentation(rows: rows, nowUsing: nowUsing(engine), switching: isSwitching ? "Switching to \(title)…" : nil)
    }

    private static func switchIsUnderWay(method: HidingMethodChoice, engine: EngineStatus) -> Bool {
        guard let decided = engine.decidedFor else { return false }
        return decided != method
    }

    /// "Now using: Allowlist. Chosen automatically: macOS's allowlist works." Nil before the engine has been chosen.
    ///
    /// When the wide spacer is in use the line ends with how it works (`spacerNote`): it hides only what is left of its divider, so the
    /// person has to ⌘-drag icons there.
    public static func nowUsing(_ engine: EngineStatus?) -> String? {
        engine.map { engine in
            let line = "Now using: \(engine.kind.title). \(engine.reason)"
            return engine.kind == .spacer ? "\(line) \(spacerNote)" : line
        }
    }

    private static func row(_ choice: HidingMethodChoice, kind: HidingEngineKind, caption: String, engine: EngineStatus?) -> HidingMethodRow {
        guard let reason = engine?.unavailableReasons[kind] else {
            return HidingMethodRow(choice: choice, title: kind.title, caption: caption, isEnabled: true)
        }
        let why = sentence(reason)
        return HidingMethodRow(choice: choice, title: kind.title, caption: why.isEmpty ? caption : "\(caption) \(why)", isEnabled: false)
    }

    /// The reason as a sentence of its own: its first letter capitalised, and one full stop at the end. A first word that has a capital
    /// of its own ("macOS") is left as it is written.
    static func sentence(_ reason: String) -> String {
        var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        guard let first = text.first else { return "" }
        let firstWord = text.prefix { !$0.isWhitespace }
        if firstWord.dropFirst().contains(where: \.isUppercase) { return text + "." }
        return first.uppercased() + text.dropFirst() + "."
    }
}

/// The words of the rest of Settings › Advanced.
public enum AdvancedCopy {
    /// The question asked before the clock and Control Center can be hidden.
    public static let allowClockTitle = "Allow hiding the clock and Control Center?"
    public static let allowClockText = "The volume and brightness pop-ups and other system controls can stop working while they're hidden. You can turn this off at any time."
    public static let allowClockConfirm = "Allow"
    public static let allowClockCancel = "Cancel"

    /// Whether changing "Allow hiding the clock and Control Center" asks first: turning it on does, turning it off never does.
    public static func asksBeforeAllowingClock(turningOn: Bool) -> Bool {
        turningOn
    }

    /// What the radio buttons of "When hidden icons don't fit" are called, and what each does.
    public static func title(for policy: NoRoomPolicy) -> String {
        switch policy {
        case .secondBar: "Open the second bar"
        case .swap: "Hide some shown icons to make room"
        case .hideAppMenus: "Hide the front app's menus"
        }
    }

    public static func caption(for policy: NoRoomPolicy) -> String {
        switch policy {
        case .secondBar: "Hidden icons that don't fit open in a bar of their own under the menu bar."
        case .swap: "Mantel hides shown icons from the right until the revealed ones fit, and brings them back afterwards."
        case .hideAppMenus: "Mantel briefly becomes the front app so its short menu leaves room. Its Dock icon shows for a moment."
        }
    }
}
