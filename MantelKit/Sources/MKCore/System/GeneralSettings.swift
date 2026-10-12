import Foundation

/// What `settings.json` holds: the settings that belong to no feature.
public struct GeneralSettings: SettingsDocument {
    public static let fileName = "settings.json"
    public static let currentVersion = 1

    /// Whether the person has been through onboarding to its last step.
    public var onboardingCompleted: Bool
    /// The pane Settings was last on, as the raw value of the pane (the same words as `SettingsPage`).
    public var settingsPage: String?
    /// What reveals hidden icons besides the dots and the hotkeys, and for how long they stay revealed.
    public var reveal: RevealSettings
    /// How icons are hidden, and the exceptions.
    public var hiding: HidingSettings

    public init() {
        self.init(onboardingCompleted: false, settingsPage: nil)
    }

    public init(onboardingCompleted: Bool, settingsPage: String?, reveal: RevealSettings = RevealSettings(),
                hiding: HidingSettings = HidingSettings()) {
        self.onboardingCompleted = onboardingCompleted
        self.settingsPage = settingsPage
        self.reveal = reveal
        self.hiding = hiding
    }

    // A key missing from the file takes its default, so a file written before a key was added is still read.
    private enum CodingKeys: String, CodingKey {
        case onboardingCompleted, settingsPage, reveal, hiding
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(onboardingCompleted: try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false,
                  settingsPage: try container.decodeIfPresent(String.self, forKey: .settingsPage),
                  reveal: try container.decodeIfPresent(RevealSettings.self, forKey: .reveal) ?? RevealSettings(),
                  hiding: try container.decodeIfPresent(HidingSettings.self, forKey: .hiding) ?? HidingSettings())
    }
}
