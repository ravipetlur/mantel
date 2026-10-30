import MKCore
import MKLayout

/// Offers the icons in the menu bar: one candidate per entry.
public struct IconsProvider: CommandBarProvider {
    private let entries: @Sendable () async -> [IconSearchEntry]

    /// `entries` is asked each time the command bar opens, and gives the icons as they are then (`IconSearchEntries.build`).
    public init(entries: @escaping @Sendable () async -> [IconSearchEntry]) {
        self.entries = entries
    }

    public var name: String { "Icons" }

    public func candidates() async -> [SearchCandidate] {
        await entries().map(\.candidate)
    }
}

extension IconSearchEntry {
    /// The candidate the command bar and the icon query search this icon by.
    ///
    /// - **Title:** the app's name. **Subtitle:** the section, or the group.
    /// - **Terms:** the names the person gave it. **Weak terms:** its label, which counts for less.
    /// - **Suggested:** every icon in Hidden, which is what the person most likely opened the bar for.
    var candidate: SearchCandidate {
        SearchCandidate(id: SearchResultKind.icon(item).candidateID, kind: .icon(item), title: title, subtitle: subtitle, terms: customNames,
                        weakTerms: label.map { [$0] } ?? [], suggested: section == .hidden)
    }
}
