import Foundation

/// What pressing an icon's own hotkey does.
public enum IconHotkeyAction: Codable, Sendable, Equatable {
    /// Reveals the icon for the rehide delay and leaves it there.
    case show
    /// Reveals the icon and clicks it this way.
    case click(ClickKind)

    /// What the person calls it.
    public var title: String {
        switch self {
        case .show: "Show"
        case .click(.left): "Show and click"
        case .click(.right): "Show and right-click"
        case .click(.option): "Show and option-click"
        }
    }

    // Written as `{"kind":"show"}` or `{"kind":"click","click":"right"}`, so a file reads on its own.
    private enum CodingKeys: String, CodingKey {
        case kind, click
    }

    private enum Kind: String {
        case show, click
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .kind)
        switch Kind(rawValue: name) {
        case .show:
            self = .show
        case .click:
            self = .click(try container.decode(ClickKind.self, forKey: .click))
        case nil:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "An icon hotkey does something this version doesn't know.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .show:
            try container.encode(Kind.show.rawValue, forKey: .kind)
        case .click(let kind):
            try container.encode(Kind.click.rawValue, forKey: .kind)
            try container.encode(kind, forKey: .click)
        }
    }
}

/// What `icons.json` holds: what the person has told Mantel about individual icons, and what the command bar remembers of its use.
/// Icons are named by their `ItemID` text.
///
/// - **`searchNames`**: other names an icon is found by in the command bar, besides its app's name.
/// - **`hotkeyActions`**: what each icon's own hotkey does. (The shortcut itself is in `hotkeys.json`, under `HotkeyID.icon`.) An icon with no
///   entry shows.
/// - **`recentPicks`**: the results the person chose in the command bar, newest first.
///
/// A key this version doesn't know is ignored. An entry that names an icon this version can't read, or does something it doesn't know, is
/// left out when the file is read, and logged without saying what it held. The rest of the file is read as it is.
public struct IconPreferences: SettingsDocument {
    public static let fileName = "icons.json"
    public static let currentVersion = 1

    /// How many search names an icon has, and how long one is, in characters.
    public static let maxNamesPerItem = 5
    public static let maxNameLength = 40
    /// How many recent picks are kept.
    public static let maxRecentPicks = 20

    /// By icon. Names are always as `cleanedNames` leaves them, whichever way they got here, and an icon with none has no entry.
    public var searchNames: [ItemID: [String]] {
        didSet {
            let cleaned = Self.cleaned(searchNames)
            if cleaned != searchNames { searchNames = cleaned }
        }
    }
    public var hotkeyActions: [ItemID: IconHotkeyAction]
    /// Result IDs, newest first, at most `maxRecentPicks`.
    public var recentPicks: [String] {
        didSet {
            if recentPicks.count > Self.maxRecentPicks { recentPicks = Array(recentPicks.prefix(Self.maxRecentPicks)) }
        }
    }

    public init() {
        self.init(searchNames: [:], hotkeyActions: [:], recentPicks: [])
    }

    public init(searchNames: [ItemID: [String]] = [:], hotkeyActions: [ItemID: IconHotkeyAction] = [:], recentPicks: [String] = []) {
        self.searchNames = Self.cleaned(searchNames)
        self.hotkeyActions = hotkeyActions
        self.recentPicks = Array(recentPicks.prefix(Self.maxRecentPicks))
    }

    /// Search names as they are kept: trimmed, none empty, each cut to `maxNameLength` characters, and the first `maxNamesPerItem` of them.
    public static func cleanedNames(_ names: [String]) -> [String] {
        var kept: [String] = []
        for name in names {
            var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > maxNameLength {
                text = String(text.prefix(maxNameLength)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !text.isEmpty else { continue }
            kept.append(text)
            if kept.count == maxNamesPerItem { break }
        }
        return kept
    }

    private static func cleaned(_ names: [ItemID: [String]]) -> [ItemID: [String]] {
        var result: [ItemID: [String]] = [:]
        for (item, list) in names {
            let kept = cleanedNames(list)
            if !kept.isEmpty { result[item] = kept }
        }
        return result
    }

    // MARK: Codable

    // A key missing from the file takes its default, so a file written before a key was added is still read.
    private enum CodingKeys: String, CodingKey {
        case searchNames, hotkeyActions, recentPicks
    }

    /// A value that is read when it can be and is nil when it can't, so that one entry this version doesn't understand doesn't send the
    /// whole file aside.
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var skipped = 0

        var names: [ItemID: [String]] = [:]
        for (key, stored) in try container.decodeIfPresent([String: Lenient<[String]>].self, forKey: .searchNames) ?? [:] {
            guard let item = ItemID(string: key), let list = stored.value else {
                skipped += 1
                continue
            }
            names[item] = list
        }

        var actions: [ItemID: IconHotkeyAction] = [:]
        for (key, stored) in try container.decodeIfPresent([String: Lenient<IconHotkeyAction>].self, forKey: .hotkeyActions) ?? [:] {
            guard let item = ItemID(string: key), let action = stored.value else {
                skipped += 1
                continue
            }
            actions[item] = action
        }

        if skipped > 0 {
            Log.warning("icons", "\(skipped) saved \(skipped == 1 ? "entry" : "entries") in \(Self.fileName) named an icon or held a setting this version can't read, so \(skipped == 1 ? "it was" : "they were") left out")
        }
        self.init(searchNames: names, hotkeyActions: actions,
                  recentPicks: try container.decodeIfPresent([String].self, forKey: .recentPicks) ?? [])
    }

    /// An icon whose ID couldn't be read back as the same icon (`ItemID.isRepresentable`) isn't written: the file would name another one.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(searchNames.filter { $0.key.isRepresentable }, forKey: .searchNames)
        try container.encode(hotkeyActions.filter { $0.key.isRepresentable }, forKey: .hotkeyActions)
        try container.encode(recentPicks, forKey: .recentPicks)
    }
}
