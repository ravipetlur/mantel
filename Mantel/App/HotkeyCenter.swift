import Carbon.HIToolbox
import MKCore

/// Why a hotkey couldn't be registered.
nonisolated enum HotkeyRegistrationError: Error, Equatable, Sendable {
    /// Another app has registered the same shortcut (`eventHotKeyExistsErr`), or this one has.
    case alreadyTaken
    /// Carbon refused for another reason; the status it gave.
    case osStatus(Int32)
}

/// What came of giving an action a shortcut.
nonisolated enum HotkeySetOutcome: Equatable, Sendable {
    /// Kept, and registered with macOS.
    case saved
    /// Not kept, and the shortcut the action had is as it was; the text says why, for the person.
    case notSaved(String)
    /// Kept, but macOS wouldn't register it (another app has it, most likely). The other app may let go of it.
    case savedButNotRegistered(HotkeyRegistrationError)
}

/// Mantel's global hotkeys, on Carbon's `RegisterEventHotKey`: it works without any permission and says when a key goes up
/// as well as when it goes down, which push-to-talk later needs.
///
/// One event handler on the application's event target takes both kinds of event for every hotkey. Each registration gets an
/// `EventHotKeyID` with the signature 'MNTL' and an id of its own, which is how an event is traced back to the action.
/// Carbon delivers the events on the main thread, which is where the handler is called.
///
/// What it registers is what it is given: the caller leaves out Fn (Carbon can't represent it) and decides whether a combo
/// is fit to register (`KeyCombo.lacksModifier`).
@MainActor
final class HotkeyCenter {
    enum Event {
        case pressed, released
    }

    private struct Registration {
        let carbonID: UInt32
        let reference: EventHotKeyRef
        let handler: (Event) -> Void
    }

    /// 'MNTL' as a four-character code.
    private static let signature: OSType = 0x4D4E_544C

    private var registrations: [HotkeyID: Registration] = [:]
    private var idsByCarbonID: [UInt32: HotkeyID] = [:]
    private var nextCarbonID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    /// Registers `combo` for `id`, replacing what `id` had. `handler` is called on the main thread for each press and
    /// release. A combo another app has taken throws `.alreadyTaken`, and `id` has no registration after it.
    func register(_ id: HotkeyID, _ combo: KeyCombo, handler: @escaping (Event) -> Void) throws(HotkeyRegistrationError) {
        unregister(id)
        try installEventHandlerIfNeeded()

        let carbonID = nextCarbonID
        nextCarbonID += 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.modifiers.carbonFlags,
                                         EventHotKeyID(signature: Self.signature, id: carbonID),
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            throw status == OSStatus(eventHotKeyExistsErr) ? .alreadyTaken : .osStatus(status)
        }
        registrations[id] = Registration(carbonID: carbonID, reference: reference, handler: handler)
        idsByCarbonID[carbonID] = id
    }

    func unregister(_ id: HotkeyID) {
        guard let registration = registrations.removeValue(forKey: id) else { return }
        idsByCarbonID[registration.carbonID] = nil
        UnregisterEventHotKey(registration.reference)
    }

    func unregisterAll() {
        for id in Array(registrations.keys) {
            unregister(id)
        }
    }

    isolated deinit {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    // MARK: Events

    private func installEventHandlerIfNeeded() throws(HotkeyRegistrationError) {
        guard eventHandler == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        var handler: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), hotkeyEventCallback, types.count, &types,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr, let handler else { throw .osStatus(status) }
        eventHandler = handler
    }

    /// Passes a hotkey event to the action it belongs to. False if this isn't one of ours.
    fileprivate func handle(carbonID: UInt32, signature: OSType, kind: UInt32) -> Bool {
        guard signature == Self.signature, let id = idsByCarbonID[carbonID], let registration = registrations[id] else {
            return false
        }
        switch Int(kind) {
        case kEventHotKeyPressed: registration.handler(.pressed)
        case kEventHotKeyReleased: registration.handler(.released)
        default: return false
        }
        return true
    }
}

/// The Carbon callback: a C function, so it can't be isolated to the main actor, and it doesn't need to be. Carbon calls it
/// on the main thread, and `MainActor.assumeIsolated` says so to the compiler (and stops the app if that is ever not so).
private nonisolated func hotkeyEventCallback(_ call: EventHandlerCallRef?, _ event: EventRef?,
                                 _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return OSStatus(eventNotHandledErr) }
    let kind = GetEventKind(event)

    let center = Unmanaged<HotkeyCenter>.fromOpaque(userData)
    let handled = MainActor.assumeIsolated {
        center.takeUnretainedValue().handle(carbonID: hotKeyID.id, signature: hotKeyID.signature, kind: kind)
    }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
