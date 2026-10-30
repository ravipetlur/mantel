import CoreFoundation
import Foundation
import MKCore

/// Where a preference lives: an app's domain, or the global domain that every app reads, for this user and either this Mac or any.
public struct PreferencesDomain: Codable, Sendable, Hashable {
    /// The name of the domain: an app's bundle ID, or `NSGlobalDomain` for the domain every app reads
    /// (`kCFPreferencesAnyApplication`).
    public let application: String
    /// For this Mac only (`defaults -currentHost`, the file in `ByHost`) and not for every Mac the user's account is on.
    public let currentHost: Bool

    public init(application: String, currentHost: Bool) {
        self.application = application
        self.currentHost = currentHost
    }

    /// The name of the global domain.
    public static let globalName = "NSGlobalDomain"

    /// What every app reads, for this Mac: where the icon spacing keys live.
    public static let globalCurrentHost = PreferencesDomain(application: globalName, currentHost: true)
}

/// Reads and writes preferences (`defaults`). Only `cfprefsd` may write them: a file under `~/Library/Preferences` is never edited.
public protocol PreferencesService: Sendable {
    /// The value now, read afresh; nil when the domain has none for the key.
    func value(forKey key: String, in domain: PreferencesDomain) -> PlistValue?
    /// Writes (nil removes) and synchronizes. False when the preferences service didn't take it.
    func set(_ value: PlistValue?, forKey key: String, in domain: PreferencesDomain) -> Bool
}

/// The real preferences, through `CFPreferences`, for the current user.
///
/// - The `-currentHost` global domain is `~/Library/Preferences/ByHost/.GlobalPreferences.<UUID>.plist`. `cfprefsd` caches it and is the
///   one that writes it; this type never touches the file.
/// - A value that isn't a property list type of Mantel's reads as nil. The keys Mantel reads are numbers.
///
/// A test never makes one: it changes the person's real preferences. Tests use a fake `PreferencesService`.
public struct LivePreferences: PreferencesService {
    public init() {}

    public func value(forKey key: String, in domain: PreferencesDomain) -> PlistValue? {
        let target = Self.target(of: domain)
        // Reads what another process (`defaults`, an app) changed since this one last looked.
        CFPreferencesSynchronize(target.application, kCFPreferencesCurrentUser, target.host)
        guard let raw = CFPreferencesCopyValue(key as CFString, target.application, kCFPreferencesCurrentUser, target.host) else {
            return nil
        }
        return PlistValue(propertyList: raw)
    }

    public func set(_ value: PlistValue?, forKey key: String, in domain: PreferencesDomain) -> Bool {
        let target = Self.target(of: domain)
        CFPreferencesSetValue(key as CFString, value.map { $0.propertyList as CFPropertyList }, target.application,
                              kCFPreferencesCurrentUser, target.host)
        return CFPreferencesSynchronize(target.application, kCFPreferencesCurrentUser, target.host)
    }

    private static func target(of domain: PreferencesDomain) -> (application: CFString, host: CFString) {
        let application: CFString = domain.application == PreferencesDomain.globalName
            ? kCFPreferencesAnyApplication : domain.application as CFString
        let host: CFString = domain.currentHost ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
        return (application, host)
    }
}
