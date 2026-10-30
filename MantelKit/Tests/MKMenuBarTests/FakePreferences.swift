import Foundation
import MKCore
import Synchronization

@testable import MKMenuBar

/// A preferences service of a test's own. It keeps what it is given in memory and reaches nothing else: no real preferences domain, no
/// file, no `cfprefsd`. A test that touches the spacing keys does it through one of these and never through `LivePreferences`.
final class FakePreferences: PreferencesService {
    /// One call of `set`.
    struct Write: Equatable {
        let key: String
        let value: PlistValue?
        let domain: PreferencesDomain
    }

    /// What the service does with a write.
    enum Behavior: Sendable {
        /// Takes it and keeps it.
        case keeps
        /// Says it didn't take it, and keeps nothing.
        case refuses
        /// Says it took it, and keeps nothing: the next read is the old value.
        case drops
        /// Says it took it and keeps this instead, for every write.
        case replaces(PlistValue?)
        /// Says it took it and keeps this instead, for the next write only; the ones after it are kept.
        case replacesOnce(PlistValue?)
    }

    /// What the service did, in order: `read(key)` and `set(key)`.
    private struct State {
        var values: [Slot: PlistValue] = [:]
        var behaviors: [String: Behavior] = [:]
        var writes: [Write] = []
        var operations: [String] = []
    }

    private struct Slot: Hashable {
        let domain: PreferencesDomain
        let key: String
    }

    private let state: Mutex<State>
    private let beforeSet = Mutex<(@Sendable (String, PlistValue?) -> Void)?>(nil)

    /// - Parameter values: what the global domain for this Mac holds to begin with, by key.
    init(_ values: [String: PlistValue] = [:], domain: PreferencesDomain = .globalCurrentHost) {
        var seeded: [Slot: PlistValue] = [:]
        for (key, value) in values { seeded[Slot(domain: domain, key: key)] = value }
        state = Mutex(State(values: seeded))
    }

    // MARK: What a test arranges and reads

    /// What the service does with writes to `key` from now on.
    func behave(_ behavior: Behavior, forKey key: String) {
        state.withLock { $0.behaviors[key] = behavior }
    }

    /// Runs at the start of every write, before anything is stored: a test looks at what exists at that moment.
    func onSet(_ body: (@Sendable (String, PlistValue?) -> Void)?) {
        beforeSet.withLock { $0 = body }
    }

    /// Changes what is held the way another program would: nothing is counted as a write.
    func change(_ key: String, to value: PlistValue?, in domain: PreferencesDomain = .globalCurrentHost) {
        state.withLock { $0.values[Slot(domain: domain, key: key)] = value }
    }

    /// The value held, without it counting as a read.
    func held(_ key: String, in domain: PreferencesDomain = .globalCurrentHost) -> PlistValue? {
        state.withLock { $0.values[Slot(domain: domain, key: key)] }
    }

    /// Every call of `set`, in order.
    var writes: [Write] { state.withLock { $0.writes } }

    /// The calls of `value` and `set`, in order: `read:<key>` and `set:<key>`.
    var operations: [String] { state.withLock { $0.operations } }

    // MARK: PreferencesService

    func value(forKey key: String, in domain: PreferencesDomain) -> PlistValue? {
        state.withLock { state in
            state.operations.append("read:\(key)")
            return state.values[Slot(domain: domain, key: key)]
        }
    }

    func set(_ value: PlistValue?, forKey key: String, in domain: PreferencesDomain) -> Bool {
        beforeSet.withLock { $0 }?(key, value)
        return state.withLock { state in
            state.operations.append("set:\(key)")
            state.writes.append(Write(key: key, value: value, domain: domain))
            let slot = Slot(domain: domain, key: key)
            switch state.behaviors[key] ?? .keeps {
            case .keeps:
                state.values[slot] = value
                return true
            case .refuses:
                return false
            case .drops:
                return true
            case .replaces(let instead):
                state.values[slot] = instead
                return true
            case .replacesOnce(let instead):
                state.values[slot] = instead
                state.behaviors[key] = .keeps
                return true
            }
        }
    }
}
