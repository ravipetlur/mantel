import AppKit
import MKCore
import SwiftUI

/// Listens for the next shortcut typed, through a local event monitor (it sees what is typed in Mantel's own windows, and
/// takes the keys so that nothing else acts on them).
///
/// - While it listens, every key goes to the recorder: Esc cancels, Delete clears, and anything else is the shortcut
///   (`RecorderOutcome`). Holding modifiers shows them (`heldModifiers`).
/// - A click anywhere, or the window or the app losing focus, stops it with nothing recorded.
/// - A key that macOS handles before the app sees it (⌘Space for Spotlight, when it is on) can't be recorded.
@Observable
final class HotkeyRecording {
    private(set) var isRecording = false
    /// The modifiers held right now, for showing while the keys are being pressed.
    private(set) var heldModifiers: ModifierSet = []

    private var monitor: Any?
    private var observers: [any NSObjectProtocol] = []
    private var onActiveChange: ((Bool) -> Void)?
    private var onShortcut: ((KeyCombo?) -> Void)?

    /// Starts listening. `onActiveChange` is told when listening starts and when it ends, so that the hotkeys can be put
    /// aside meanwhile; `onShortcut` gets the combo, or nil for Delete.
    func begin(onActiveChange: @escaping (Bool) -> Void, onShortcut: @escaping (KeyCombo?) -> Void) {
        guard !isRecording else { return }
        isRecording = true
        heldModifiers = []
        self.onActiveChange = onActiveChange
        self.onShortcut = onShortcut
        onActiveChange(true)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            // Events are delivered on the main thread. Only whether to take the event leaves the isolated block.
            let taken = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return taken ? nil : event
        }
        // Another window or app coming forward ends it too, which the clicks above don't cover.
        let center = NotificationCenter.default
        let stop: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: NSApp.keyWindow, queue: .main, using: stop),
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: stop),
        ]
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
        let finished = onActiveChange
        onActiveChange = nil
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
    /// Whether the field is listening, so that the hotkeys can be put aside meanwhile.
    let onListeningChange: (Bool) -> Void

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
            recording.begin(onActiveChange: onListeningChange, onShortcut: onRecord)
        } label: {
            Text(combo.map(display) ?? "Record shortcut")
                .foregroundStyle(combo == nil ? .secondary : .primary)
                .frame(width: Self.fieldWidth)
        }
        .accessibilityLabel("Shortcut for \(title)")
        .accessibilityValue(combo.map(display) ?? "None")
        .accessibilityHint("Starts recording a new shortcut")
    }

    /// Not a button: a click on it ends the recording (the monitor sees the click first), and must not start it again.
    private var listeningField: some View {
        let held = KeyNames.glyphs(for: recording.heldModifiers)
        return Text(held.isEmpty ? "Type shortcut" : held + "…")
            .foregroundStyle(.secondary)
            .frame(width: Self.fieldWidth)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2))
            .accessibilityLabel("Recording a shortcut for \(title)")
            .accessibilityHint("Press the new shortcut, Delete to remove it, or Escape to cancel")
    }
}
