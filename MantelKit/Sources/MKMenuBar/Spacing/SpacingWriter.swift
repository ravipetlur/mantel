import Foundation
import MKCore

/// What the two spacing keys held before Mantel first changed them (nil for a key that wasn't there).
public struct SpacingOriginal: Sendable, Equatable {
    public let spacing: Int?
    public let padding: Int?

    public init(spacing: Int?, padding: Int?) {
        self.spacing = spacing
        self.padding = padding
    }
}

/// What the icon spacing is now.
public struct SpacingState: Sendable, Equatable {
    /// What `NSStatusItemSpacing` holds now: nil when there is no whole number there.
    public let spacing: Int?
    /// What `NSStatusItemSelectionPadding` holds now: nil when there is no whole number there.
    public let padding: Int?
    public let preset: IconSpacingPreset
    /// What the keys held before Mantel first changed them, when Mantel has changed them: what "Restore original spacing" puts back. It can be
    /// values, and not "macOS default". Nil when Mantel hasn't changed the keys.
    public let original: SpacingOriginal?

    public init(spacing: Int?, padding: Int?, preset: IconSpacingPreset, original: SpacingOriginal?) {
        self.spacing = spacing
        self.padding = padding
        self.preset = preset
        self.original = original
    }
}

/// Reads and writes the icon spacing: the two global preferences macOS reads for this Mac (`NSStatusItemSpacing` and
/// `NSStatusItemSelectionPadding`). A change is Mantel's own and is kept: it stays across quits and resets, and only
/// `restoreOriginal` puts the keys back as they were before Mantel first changed them. Apps pick the new spacing up when they next start.
public actor SpacingWriter {
    private let defaults: DefaultsAccess
    private let journal: Journal

    private static let domain = PreferencesDomain.globalCurrentHost

    public init(defaults: DefaultsAccess, journal: Journal) {
        self.defaults = defaults
        self.journal = journal
    }

    /// The keys' values now, the preset they are, and what the keys held before Mantel first changed them.
    public func current() async -> SpacingState {
        let spacing = Self.wholeNumber(await defaults.value(forKey: IconSpacing.spacingKey, in: Self.domain))
        let padding = Self.wholeNumber(await defaults.value(forKey: IconSpacing.paddingKey, in: Self.domain))
        let kept = await journal.keptRecords()
        let first = Self.keptOriginal(of: IconSpacing.spacingKey, in: kept)
        let second = Self.keptOriginal(of: IconSpacing.paddingKey, in: kept)
        var original: SpacingOriginal?
        if first != nil || second != nil {
            // A key Mantel hasn't changed (only one of the two has a record) still holds what it did before.
            original = SpacingOriginal(spacing: first.map { Self.wholeNumber($0) } ?? spacing,
                                       padding: second.map { Self.wholeNumber($0) } ?? padding)
        }
        return SpacingState(spacing: spacing, padding: padding, preset: IconSpacing.preset(spacing: spacing, padding: padding),
                            original: original)
    }

    /// Sets both keys to the preset's values, as a change Mantel keeps. "macOS default" removes both. A key that already holds what it is
    /// to hold, and that nothing is recorded for, is left alone. Both keys are changed or neither is.
    ///
    /// - Throws: `DefaultsAccessError` (`.notPersisted`, `.keptByMantel`) or the journal's errors; nothing is changed then.
    public func apply(_ preset: IconSpacingPreset, custom: IconSpacingValues) async throws {
        let target = IconSpacing.values(for: preset, custom: custom)
        try await defaults.writeAll([
            DefaultsChange(key: IconSpacing.spacingKey, value: target.map { .integer($0.spacing) }),
            DefaultsChange(key: IconSpacing.paddingKey, value: target.map { .integer($0.padding) }),
        ], in: Self.domain, lifetime: .kept)
    }

    /// Puts the two keys back as they were before Mantel first changed them (what the kept records hold), whatever their age. Returns what
    /// couldn't be put back; those records stay.
    public func restoreOriginal() async -> [ReplayFailure] {
        await journal.restoreKept(where: { Self.isSpacingRecord($0) }, using: DefaultsJournalRestorer(access: defaults))
    }

    // MARK: Reading what the keys hold

    /// A whole number, from what a preference may hold for one: a number, or a text that is one.
    static func wholeNumber(_ value: PlistValue?) -> Int? {
        switch value {
        case .integer(let number)?:
            return number
        case .real(let number)?:
            guard number.isFinite, number == number.rounded(), let whole = Int(exactly: number) else { return nil }
            return whole
        case .string(let text)?:
            return Int(text.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    /// What the kept record of the key says it held before: `.some(nil)` when the key wasn't there, nil when there is no record.
    private static func keptOriginal(of key: String, in records: [JournalRecord]) -> PlistValue?? {
        for record in records {
            if case .defaultsKey(let application, let recordKey, let currentHost, let original) = record.entry,
               application == domain.application, currentHost == domain.currentHost, recordKey == key {
                return .some(original)
            }
        }
        return nil
    }

    private static func isSpacingRecord(_ record: JournalRecord) -> Bool {
        guard case .defaultsKey(let application, let key, let currentHost, _) = record.entry else { return false }
        return application == domain.application && currentHost == domain.currentHost
            && (key == IconSpacing.spacingKey || key == IconSpacing.paddingKey)
    }
}
