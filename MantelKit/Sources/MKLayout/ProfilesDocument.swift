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
    /// Version 2 holds what a version 1 file held, cleaned of the icons that were saved under another app's names (`migrate`), and the
    /// apps whose icons are yet to be checked (`SectionModel.unchecked`).
    public static let currentVersion = 2

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

    /// Brings a version 1 file to version 2, in each profile's sections:
    /// - **Every icon of an app that is named with one of Mantel's own names is dropped,** from the sections' lists and the groups'. No other
    ///   app has an item so called.
    /// - **Every app that has an icon listed is marked unchecked** (`SectionModel.unchecked`): its icons are checked against what it lists
    ///   when it is first read whole.
    ///
    /// Where an app is, its group, the spacers, the groups, the system items and the marker are left as they are.
    public static func migrate(_ document: JSONValueTree, from version: Int) throws -> JSONValueTree {
        guard version == 1 else {
            throw SettingsMigrationError.noMigration(file: fileName, from: version, to: currentVersion)
        }
        var migrated = document
        guard let profiles = document["profiles"] as? [[String: Any]] else { return migrated }
        migrated["profiles"] = profiles.map { profile -> [String: Any] in
            var profile = profile
            if let sections = profile["sections"] as? [String: Any] { profile["sections"] = cleanedSections(sections) }
            return profile
        }
        return migrated
    }

    private static func cleanedSections(_ sections: [String: Any]) -> [String: Any] {
        var cleaned = sections
        var apps: Set<String> = []
        /// The list without the records named with Mantel's own names, and how many of those were before `marker`.
        func kept(_ list: [Any], marker: Int?) -> (list: [Any], droppedBeforeMarker: Int) {
            var droppedBeforeMarker = 0
            let remaining = list.enumerated().filter { place, entry in
                guard let text = entry as? String, let id = ItemID(string: text) else { return true }
                // Marked from every record, the dropped ones too: an app whose every record was named with Mantel's names is checked
                // all the same, and the settings under those names are handed on then.
                if !id.isSystem, id.bundleID != OwnItems.owner { apps.insert(id.bundleID) }
                if SectionModel.namesAnOwnItem(id) {
                    if let marker, place < marker { droppedBeforeMarker += 1 }
                    return false
                }
                return true
            }.map(\.element)
            return (remaining, droppedBeforeMarker)
        }
        // The marker for new apps is before the icon at `newItemsIndex` in the list of the section new apps go to: it stays before the same one.
        let newItems = (sections["newItems"] as? String) ?? MenuBarSection.shown.rawValue
        let marker = sections["newItemsIndex"] as? Int
        for key in ["order", "groupItems"] {
            guard let lists = sections[key] as? [String: Any] else { continue }
            var rewritten: [String: Any] = [:]
            for (name, list) in lists {
                guard let list = list as? [Any] else {
                    rewritten[name] = list
                    continue
                }
                let isMarkerList = key == "order" && name == newItems
                let result = kept(list, marker: isMarkerList ? marker : nil)
                if isMarkerList, let marker { cleaned["newItemsIndex"] = marker - result.droppedBeforeMarker }
                if !result.list.isEmpty { rewritten[name] = result.list }
            }
            cleaned[key] = rewritten
        }
        let before = (sections["unchecked"] as? [String]) ?? []
        cleaned["unchecked"] = Array(Set(before).union(apps)).sorted()
        return cleaned
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
