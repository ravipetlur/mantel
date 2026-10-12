import AppKit
import MKCore
import SwiftUI

/// Said to VoiceOver when a recording can hear, or has ended without being able to. The listening field has no label of its own to say it
/// with: SwiftUI's accessibility never finished resolving a `Text` that had one, in a row whose title was linked to its content, and the app
/// ended in a stack overflow when an assistive tool read the window then. The title isn't linked to the field now: VoiceOver reads it as
/// the field's neighbour, so this names the action and says what the field is doing.
private func announce(_ text: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
        .announcement: text,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
    ])
}

/// Listens for the next shortcut typed, through a local event monitor (it sees what is typed in Mantel's own windows, and
/// takes the keys so that nothing else acts on them).
///
/// - While it listens, every key goes to the recorder: Esc cancels, Delete clears, and anything else is the shortcut
///   (`RecorderOutcome`). Holding modifiers shows them (`heldModifiers`).
/// - A click anywhere, or the window or the app losing focus, stops it with nothing recorded.
/// - A key that macOS handles before the app sees it (⌘Space for Spotlight, when it is on) can't be recorded.
/// - A monitor only hears the keys of the app that is active, so a recording starts by bringing Mantel to the front with its window key
///   (`bringForward`). A recording started while Mantel is behind another app (an assistive tool presses the field, say) may not get
///   that: **the hotkeys are put aside only once Mantel is active** (`RecordingStart`), and a recording that has waited a second for that
///   ends, without having touched them.
/// - **Nothing in the field carries an accessibility label while it listens** (see `announce`): what it is doing is announced when the hotkeys
///   are put aside, and a recording that ends for want of the front is announced as that.
@Observable
final class HotkeyRecording {
    private(set) var isRecording = false
    /// The modifiers held right now, for showing while the keys are being pressed.
    private(set) var heldModifiers: ModifierSet = []

    private var monitor: Any?
    private var observers: [any NSObjectProtocol] = []
    private var start = RecordingStart()
    private var activationObserver: (any NSObjectProtocol)?
    private var activationTimeout: Task<Void, Never>?
    private var title = ""
    private var onHotkeysAside: ((Bool) -> Void)?
    private var onShortcut: ((KeyCombo?) -> Void)?

    /// Starts a recording. `title` is what the shortcut is for, which the announcements name. `window` is the window the field is in, whose
    /// losing the focus ends it. `bringForward` makes Mantel the active app with that window key, which macOS may not grant.
    /// `onHotkeysAside` is told `true` once the recording can hear (Mantel is active) and `false` when it ends, if it was told `true`, so that
    /// the hotkeys are put aside only while it listens. `onShortcut` gets the combo, or nil for Delete.
    func begin(title: String, window: NSWindow?, bringForward: () -> Void, onHotkeysAside: @escaping (Bool) -> Void,
               onShortcut: @escaping (KeyCombo?) -> Void) {
        guard !isRecording else { return }
        isRecording = true
        heldModifiers = []
        self.title = title
        self.onHotkeysAside = onHotkeysAside
        self.onShortcut = onShortcut
        bringForward()

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            // Events are delivered on the main thread. Only whether to take the event leaves the isolated block.
            let taken = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return taken ? nil : event
        }
        // Another window or app coming forward ends it too, which the clicks above don't cover. The window is the field's own, not whichever
        // is key now: when Mantel is behind another app none is, and that would be every window there is.
        let center = NotificationCenter.default
        let stop: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
        observers = [center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: stop)]
        if let window {
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: stop))
        }

        let first = start.began(mantelIsActive: NSApp.isActive)
        if first == .nothing { waitForActivation() } else { perform(first) }
    }

    /// Mantel isn't the active app yet: the recording waits for it, for as long as `RecordingStart.activationWait`.
    private func waitForActivation() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stopWaiting()
                self.perform(self.start.mantelBecameActive())
            }
        }
        activationTimeout = Task { [weak self] in
            try? await Task.sleep(for: RecordingStart.activationWait)
            guard !Task.isCancelled, let self else { return }
            self.perform(self.start.waitedLongEnough())
        }
    }

    private func stopWaiting() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        activationTimeout?.cancel()
        activationTimeout = nil
    }

    private func perform(_ step: RecordingStart.Step) {
        switch step {
        case .putHotkeysAside:
            onHotkeysAside?(true)
            // Said now, when the recording can hear, and not at the press: a recording that waits for Mantel to become active hears nothing
            // until it has.
            announce(RecorderCopy.announcement(for: title))
        case .giveUp:
            Log.warning("hotkeys", "a shortcut recording ended: Mantel wasn't made the active app, so it couldn't hear any keys")
            announce(RecorderCopy.couldntComeToTheFront)
            end()
        case .nothing:
            break
        }
    }

    /// Stops listening. Does nothing when it isn't.
    func end() {
        guard isRecording else { return }
        isRecording = false
        heldModifiers = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        stopWaiting()
        // The hotkeys come back only if they were put aside.
        let finished = start.ended() ? onHotkeysAside : nil
        onHotkeysAside = nil
        onShortcut = nil
        finished?(false)
    }

    /// A recording that is still on when this goes (the field left the screen mid-recording) must not leave its monitor
    /// behind, nor the hotkeys aside.
    isolated deinit {
        end()
    }

    /// Whether the recorder takes the event, so that nothing else sees it.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            heldModifiers = ModifierSet(cocoaFlags: UInt(event.modifierFlags.rawValue)).subtracting(.function)
            return true
        case .keyDown:
            // A key held down repeats, and the repeats are neither a second shortcut nor a beep.
            guard !event.isARepeat else { return true }
            let outcome = RecorderOutcome.forKeyDown(keyCode: event.keyCode, cocoaFlags: UInt(event.modifierFlags.rawValue))
            let deliver = onShortcut
            end()
            switch outcome {
            case .cancel: break
            case .clear: deliver?(nil)
            case .record(let combo): deliver?(combo)
            }
            return true
        default:
            // A click: it ends the recording and goes on to whatever was clicked.
            end()
            return false
        }
    }
}

/// The field a shortcut is recorded in: it shows the shortcut (or "Record shortcut"), listens when it is clicked, and has a
/// button to clear it. The caller decides what a recorded shortcut means; this only reports it.
struct HotkeyRecorder: View {
    /// What the shortcut is for, for VoiceOver.
    let title: String
    let combo: KeyCombo?
    /// How a shortcut reads (`⌃⌥⌘K`).
    let display: (KeyCombo) -> String
    /// A recorded shortcut, or nil when Delete cleared it.
    let onRecord: (KeyCombo?) -> Void
    /// Makes Mantel the active app with the field's window key, when a recording starts.
    let bringForward: () -> Void
    /// Told `true` once the field is listening, which is when Mantel is the active app (not at the press: a recording started while another
    /// app is in front waits for that), and `false` when the recording ends, if it was told `true`. The hotkeys are put aside only between.
    let onHotkeysAside: (Bool) -> Void
    /// The window the field is in.
    let window: () -> NSWindow?

    @State private var recording = HotkeyRecording()

    private static let fieldWidth: CGFloat = 150

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                if recording.isRecording {
                    listeningField
                } else {
                    restingField
                }
                if combo != nil, !recording.isRecording {
                    Button(action: { onRecord(nil) }) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove the shortcut")
                    .accessibilityLabel("Remove the shortcut for \(title)")
                }
            }
            if recording.isRecording {
                Text("Press the keys. Esc cancels, Delete removes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { recording.end() }
    }

    private var restingField: some View {
        Button {
            recording.begin(title: title, window: window(), bringForward: bringForward, onHotkeysAside: onHotkeysAside, onShortcut: onRecord)
        } label: {
            Text(combo.map(display) ?? "Record shortcut")
                .foregroundStyle(combo == nil ? .secondary : .primary)
                .frame(width: Self.fieldWidth)
        }
        .accessibilityLabel("Shortcut for \(title)")
        .accessibilityValue(combo.map(display) ?? "None")
        .accessibilityHint("Starts recording a new shortcut")
    }

    /// Not a button: a click on it ends the recording (the monitor sees the click first), and must not start it again. It has no
    /// accessibility label of its own (see `announce`): its own text is what it is.
    private var listeningField: some View {
        let held = KeyNames.glyphs(for: recording.heldModifiers)
        return Text(held.isEmpty ? "Type shortcut" : held + "…")
            .foregroundStyle(.secondary)
            .frame(width: Self.fieldWidth)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2))
    }
}
