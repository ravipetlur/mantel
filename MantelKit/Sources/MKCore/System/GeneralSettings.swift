import Foundation

/// What `settings.json` holds: the settings that belong to no feature.
public struct GeneralSettings: SettingsDocument {
    public static let fileName = "settings.json"
    public static let currentVersion = 1

    /// Whether the person has been through onboarding to its last step.
    public var onboardingCompleted: Bool
    /// The pane Settings was last on, as the raw value of the pane (the same words as `SettingsPage`).
    public var settingsPage: String?

    public init() {
        self.init(onboardingCompleted: false, settingsPage: nil)
    }

    public init(onboardingCompleted: Bool, settingsPage: String?) {
        self.onboardingCompleted = onboardingCompleted
        self.settingsPage = settingsPage
    }

    // A key missing from the file takes its default, so a file written before a key was added is still read.
    private enum CodingKeys: String, CodingKey {
        case onboardingCompleted, settingsPage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(onboardingCompleted: try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false,
                  settingsPage: try container.decodeIfPresent(String.self, forKey: .settingsPage))
    }
}
