import Foundation
import MKCore
import MKLayout
import Synchronization

@testable import MKSearch

/// Values the search tests share. Every bundle ID is a synthetic `com.example.*` one.
enum SearchFixtures {
    static func itemID(_ bundleID: String, _ name: String = "main") -> ItemID {
        ItemID(bundleID: bundleID, key: .identifier(name))
    }

    /// An item the inventory read, concealed (no frames), unless it says what it is of Mantel's.
    static func item(_ id: ItemID, appName: String? = nil, label: String? = nil, isMantel: Bool = false, ownKind: OwnItemKind? = nil)
        -> MenuBarItem {
        MenuBarItem(id: id, ownerBundleID: id.bundleID, appName: appName, label: label, frames: [:], overflowedOn: [], isMantel: isMantel,
                    ownKind: ownKind)
    }

    static func inventory(_ items: [MenuBarItem]) -> Inventory {
        Inventory(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), bars: [], items: items, chevrons: [:], reach: [], problems: [])
    }

    static func entry(_ item: ItemID, _ appName: String?, label: String? = nil, names: [String] = [], section: MenuBarSection? = .shown,
                      groupTitle: String? = nil) -> IconSearchEntry {
        IconSearchEntry(item: item, appName: appName, label: label, customNames: names, section: section, groupTitle: groupTitle)
    }

    /// An icon candidate, as the icons provider makes one from an entry. The icon's app is `com.example.` and the title's letters, unless
    /// it is given.
    static func iconCandidate(_ title: String, bundleID: String? = nil, terms: [String] = [], weakTerms: [String] = [],
                              subtitle: String? = nil, boost: Int = 0, suggested: Bool = false) -> SearchCandidate {
        let item = itemID(bundleID ?? "com.example." + title.lowercased().filter { $0.isLetter || $0.isNumber })
        return SearchCandidate(id: SearchResultKind.icon(item).candidateID, kind: .icon(item), title: title, subtitle: subtitle, terms: terms,
                               weakTerms: weakTerms, boost: boost, suggested: suggested)
    }
}

/// A provider that offers what it was given, and counts how often it was asked.
final class StubProvider: CommandBarProvider {
    let name: String
    private let offered: [SearchCandidate]
    private let asked = Mutex(0)

    init(_ name: String = "Stub", offering offered: [SearchCandidate]) {
        self.name = name
        self.offered = offered
    }

    var timesAsked: Int { asked.withLock { $0 } }

    func candidates() async -> [SearchCandidate] {
        asked.withLock { $0 += 1 }
        return offered
    }
}

/// A provider whose first answer waits until it is let go, and whose later ones come at once with other candidates.
final class FirstCallWaitsProvider: CommandBarProvider {
    let name = "Waits"
    private let first: [SearchCandidate]
    private let later: [SearchCandidate]
    private let calls = Mutex(0)
    private let started = AsyncStream<Void>.makeStream()
    private let release = AsyncStream<Void>.makeStream()

    init(first: [SearchCandidate], later: [SearchCandidate]) {
        self.first = first
        self.later = later
    }

    func candidates() async -> [SearchCandidate] {
        let call = calls.withLock { calls -> Int in
            calls += 1
            return calls
        }
        guard call == 1 else { return later }
        started.continuation.yield()
        for await _ in release.stream { break }
        return first
    }

    /// Returns when the first call has begun waiting.
    func firstCallStarted() async {
        for await _ in started.stream { break }
    }

    func releaseFirstCall() {
        release.continuation.yield()
    }
}
