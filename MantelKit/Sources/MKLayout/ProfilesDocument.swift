import MKCore

/// A named set of sections. There is one, "Default", for now.
public struct Profile: Codable, Sendable, Equatable {
    public var name: String
    public var sections: SectionModel

    public init(name: String, sections: SectionModel = SectionModel()) {
        self.name = name
        self.sections = sections
    }

    private enum CodingKeys: String, CodingKey {
        case name, sections
    }

    // A key missing from the file takes its default, so a file written before a key was added is still read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        sections = try container.decodeIfPresent(SectionModel.self, forKey: .sections) ?? SectionModel()
    }
}

/// What `profiles.json` holds: the profiles, and which one is in use.
///
/// The profile in use always exists. A document that names one it doesn't have (a file that is empty, or was edited by hand)
/// falls back to "Default", which is made, empty, if it isn't there either.
public struct ProfilesDocument: SettingsDocument {
    public static let fileName = "profiles.json"
    public static let currentVersion = 1

    public static let defaultName = "Default"

    public var profiles: [Profile]
    public var activeProfileName: String

    public init() {
        profiles = [Profile(name: Self.defaultName)]
        activeProfileName = Self.defaultName
    }

    public init(profiles: [Profile], activeProfileName: String) {
        self.profiles = profiles
        self.activeProfileName = activeProfileName
        makeActiveProfileExist()
    }

    /// The sections of the profile in use. Setting them makes the profile if it isn't there.
    public var active: SectionModel {
        get {
            (profiles.first { $0.name == activeProfileName } ?? profiles.first { $0.name == Self.defaultName })?.sections
                ?? SectionModel()
        }
        set {
            makeActiveProfileExist()
            if let index = profiles.firstIndex(where: { $0.name == activeProfileName }) {
                profiles[index].sections = newValue
            }
        }
    }

    private mutating func makeActiveProfileExist() {
        guard !profiles.contains(where: { $0.name == activeProfileName }) else { return }
        activeProfileName = Self.defaultName
        if !profiles.contains(where: { $0.name == Self.defaultName }) {
            profiles.append(Profile(name: Self.defaultName))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case profiles, activeProfileName
    }

    // A key missing from the file takes its default, so a file written before a key was added is still read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(profiles: try container.decodeIfPresent([Profile].self, forKey: .profiles) ?? [Profile(name: Self.defaultName)],
                  activeProfileName: try container.decodeIfPresent(String.self, forKey: .activeProfileName) ?? Self.defaultName)
    }
}
