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
    /// Where the dots are, and what ⌘-dragging shows.
    public var layout: LayoutSettings
    /// When the second bar opens, where, and how it looks.
    public var secondBar: SecondBarSettings
    /// How the dots are drawn and when they are there.
    public var dots: DotSettings
    /// Whether Mantel checks for a new version once a day. Only a build made to update itself has the setting to show.
    public var checkForUpdatesAutomatically: Bool

    public init() {
        self.init(onboardingCompleted: false, settingsPage: nil)
    }

    public init(onboardingCompleted: Bool, settingsPage: String?, reveal: RevealSettings = RevealSettings(),
                hiding: HidingSettings = HidingSettings(), layout: LayoutSettings = LayoutSettings(),
                secondBar: SecondBarSettings = SecondBarSettings(), dots: DotSettings = DotSettings(),
                checkForUpdatesAutomatically: Bool = true) {
        self.onboardingCompleted = onboardingCompleted
        self.settingsPage = settingsPage
        self.reveal = reveal
        self.hiding = hiding
        self.layout = layout
        self.secondBar = secondBar
        self.dots = dots
        self.checkForUpdatesAutomatically = checkForUpdatesAutomatically
    }

    // A key missing from the file takes its default, so a file written before a key was added is still read.
    private enum CodingKeys: String, CodingKey {
        case onboardingCompleted, settingsPage, reveal, hiding, layout, secondBar, dots, checkForUpdatesAutomatically
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(onboardingCompleted: try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false,
                  settingsPage: try container.decodeIfPresent(String.self, forKey: .settingsPage),
                  reveal: try container.decodeIfPresent(RevealSettings.self, forKey: .reveal) ?? RevealSettings(),
                  hiding: try container.decodeIfPresent(HidingSettings.self, forKey: .hiding) ?? HidingSettings(),
                  layout: try container.decodeIfPresent(LayoutSettings.self, forKey: .layout) ?? LayoutSettings(),
                  secondBar: try container.decodeIfPresent(SecondBarSettings.self, forKey: .secondBar) ?? SecondBarSettings(),
                  dots: try container.decodeIfPresent(DotSettings.self, forKey: .dots) ?? DotSettings(),
                  // On when missing, and when it isn't a true or false.
                  checkForUpdatesAutomatically: container.decodeLeniently(Bool.self, forKey: .checkForUpdatesAutomatically) ?? true)
    }
}

extension KeyedDecodingContainer {
    /// The value under `key`, or nil when the key is missing or holds something this version can't read (a case of an enum that a later
    /// version added, say). A value that can't be read is said once in the log, by its key and never by what the file held, and is read as
    /// missing: the caller's default is used, and the rest of the file is read as it is. A file written by a later version therefore still
    /// opens, where one value that throws would set the whole file aside.
    package func decodeLeniently<Value: Decodable>(_ type: Value.Type, forKey key: Key, category: String = "settings") -> Value? {
        do {
            return try decodeIfPresent(type, forKey: key)
        } catch {
            Log.warning(category, "the value of \(key.stringValue) isn't one this version knows, so its default is used")
            return nil
        }
    }
}
