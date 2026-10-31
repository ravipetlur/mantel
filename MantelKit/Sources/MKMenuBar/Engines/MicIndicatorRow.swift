import Foundation

/// What Settings › Advanced shows for "Keep the mic and camera indicator visible while they're in use": the switch, and the line under it.
public struct MicIndicatorRow: Sendable, Equatable {
    /// Whether the switch can be turned. It can't while the switches that keep the indicators visible can't be used.
    public let isEnabled: Bool
    /// What the switch does; for one that can't be turned it says why instead.
    public let caption: String
    /// Whether the caption comes with the action that has the person choose the file the switches need.
    public let offersGrant: Bool

    public init(isEnabled: Bool, caption: String, offersGrant: Bool) {
        self.isEnabled = isEnabled
        self.caption = caption
        self.offersGrant = offersGrant
    }
}

extension AdvancedCopy {
    public static let micIndicatorTitle = "Keep the mic and camera indicator visible while they're in use"
    public static let micIndicatorCaption = "Hides icons with System Settings switches while the mic or camera is in use, so macOS's orange and green dots stay visible. Goes back about 10 seconds after neither is."
    /// What the caption adds when the file the switches work on hasn't been given.
    public static let micIndicatorNeedsGrant = "Needs the “Allow in the Menu Bar” file, which Mantel hasn't been given yet."
    public static let grantButton = "Grant Access…"

    /// The row for the switch, from how the engines stand.
    ///
    /// - **The switches can be used, or nothing is known yet** (no status): the switch is on offer, and the caption says what it does.
    /// - **The file hasn't been given:** the switch is disabled, and the caption ends by saying so and offers the action that has the person
    ///   choose it.
    /// - **The switches can't be used for another reason** (the list isn't what Mantel can edit, a test's change isn't put back): disabled,
    ///   and the caption ends with that reason, as the way of hiding's own row does. There is nothing to grant.
    public static func micIndicator(engine: EngineStatus?) -> MicIndicatorRow {
        guard let reason = engine?.unavailableReasons[.approvals] else {
            return MicIndicatorRow(isEnabled: true, caption: micIndicatorCaption, offersGrant: false)
        }
        if engine?.needsPermission(.approvals) == true {
            return MicIndicatorRow(isEnabled: false, caption: "\(micIndicatorCaption) \(micIndicatorNeedsGrant)", offersGrant: true)
        }
        let why = HidingMethodRows.sentence(reason)
        return MicIndicatorRow(isEnabled: false, caption: why.isEmpty ? micIndicatorCaption : "\(micIndicatorCaption) \(why)", offersGrant: false)
    }
}
