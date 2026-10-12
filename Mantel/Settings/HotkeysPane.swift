import AppKit
import MKCommands
import MKCore
import SwiftUI

/// A line under a shortcut's field: a clash to know about, or a reason the shortcut won't work.
struct HotkeyWarning: Identifiable, Equatable {
    let text: String
    /// Whether the shortcut won't work at all (red), rather than may not (orange).
    let isError: Bool

    var id: String { text }
}

/// What the Hotkeys pane shows and does: the bindings and the macOS shortcuts they are checked against, kept in step with
/// the coordinator, which saves and registers them.
@Observable
final class HotkeysModel {
    private let coordinator: AppCoordinator
    private(set) var bindings: [HotkeyID: KeyCombo]
    private(set) var failures: [HotkeyID: HotkeyRegistrationError]
    private(set) var systemShortcuts: [SymbolicHotkey] = []
    /// The actions whose last recorded shortcut wasn't kept, with why, so that the reason stays under the field.
    private var refused: [HotkeyID: String] = [:]
    private let translator = LiveKeyTranslator()

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        bindings = coordinator.hotkeyBindings.bindings
        failures = coordinator.hotkeyFailures
    }

    /// Reads everything again: macOS's shortcuts change in System Settings while Mantel runs.
    func refresh() {
        bindings = coordinator.hotkeyBindings.bindings
        failures = coordinator.hotkeyFailures
        systemShortcuts = SystemShortcuts.read()
    }

    /// The Settings window, which the recorder's field is in.
    var settingsWindow: NSWindow? { coordinator.settingsNSWindow }

    func display(_ combo: KeyCombo) -> String {
        KeyNames.display(combo, translator: translator)
    }

    /// A shortcut recorded for `id`, or nil for one cleared. Fn is left out of what is kept, as it is of what is registered.
    /// A combo with no ⌘, ⌃ or ⌥ isn't kept: the shortcut stays as it was, and the reason shows under the field. Every other
    /// clash is shown and the shortcut is kept.
    func record(_ combo: KeyCombo?, for id: HotkeyID) {
        defer { refresh() }
        guard let combo = combo?.withoutFunction else {
            note(coordinator.setHotkey(nil, for: id), for: id)
            return
        }
        let clashes = ClashDetector.clashes(for: combo, assigning: id, mantel: bindings, system: systemShortcuts)
        if clashes.contains(where: \.preventsSaving) {
            refused[id] = HotkeyClash.noModifier.message(actionTitle: HotkeyAction.title(for:))
            return
        }
        note(coordinator.setHotkey(combo, for: id), for: id)
    }

    /// Keeps the reason a shortcut wasn't saved; one that was saved clears it. (A shortcut macOS won't register is saved, and
    /// its reason is `failures`'s.)
    private func note(_ outcome: HotkeySetOutcome, for id: HotkeyID) {
        switch outcome {
        case .saved, .savedButNotRegistered: refused[id] = nil
        case .notSaved(let reason): refused[id] = reason
        }
    }

    /// Starting a recording brings Mantel to the front with Settings the key window, so that the keys that follow are heard (a recorder
    /// only hears the active app's), also when it was started while another app was in front. That is the whole sequence of opening
    /// Settings again (`WindowShowing`), not a check that does nothing when Mantel is active: on the next turn of the main queue Mantel is
    /// asked to become active and the window is made key and ordered front, all of which is harmless when they already are, and during a
    /// takeover it counts as the person using the window.
    func bringForwardForRecording() {
        coordinator.openSettings(.hotkeys)
    }

    /// Whether the hotkeys are put aside, which they are while a recording listens, so that a key that is already a hotkey is heard and
    /// doesn't act. (The recorder says so only once Mantel is the active app: `RecordingStart`.)
    func setHotkeysAside(_ aside: Bool) {
        coordinator.setHotkeysSuspended(aside)
    }

    /// What is under `id`'s field: the reason a recorded shortcut was refused, then each clash of the one it has, then
    /// why macOS wouldn't register it.
    func warnings(for id: HotkeyID) -> [HotkeyWarning] {
        var lines: [String] = []
        var errors: [String] = []
        var seen: Set<String> = []
        func add(_ line: String, to list: inout [String]) {
            if seen.insert(line).inserted { list.append(line) }
        }

        if let reason = refused[id] {
            add(reason, to: &lines)
        }
        let clashes = bindings[id].map {
            ClashDetector.clashes(for: $0, assigning: id, mantel: bindings, system: systemShortcuts)
        } ?? []
        for clash in clashes {
            add(clash.message(actionTitle: HotkeyAction.title(for:)), to: &lines)
        }
        // Another Mantel action holding the shortcut is already said above; "another app" would be wrong.
        let clashesWithMantel = clashes.contains { if case .mantel = $0 { true } else { false } }
        if let failure = failures[id], !clashesWithMantel {
            switch failure {
            case .alreadyTaken:
                add("Another app already uses this shortcut, so it won't work here. Pick a different one.", to: &errors)
            case .osStatus(let status):
                add("macOS wouldn't register this shortcut (error \(status)). Pick a different one.", to: &errors)
            }
        }
        return lines.map { HotkeyWarning(text: $0, isError: false) } + errors.map { HotkeyWarning(text: $0, isError: true) }
    }
}

/// Settings › Hotkeys: each action Mantel can be told to do from any app, with the field its shortcut is recorded in.
struct HotkeysPane: View {
    @State private var model: HotkeysModel

    init(coordinator: AppCoordinator) {
        // Only keeps the coordinator: what the model reads is read again when the pane appears.
        _model = State(initialValue: HotkeysModel(coordinator: coordinator))
    }

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.all) { action in
                    // Not a `LabeledContent`: it links the title to the content, and SwiftUI's accessibility then never finishes resolving
                    // a field that is recording (a stack overflow when an assistive tool reads the window). A title and what it names, side
                    // by side, look the same.
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(action.title)
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 4) {
                            HotkeyRecorder(title: action.title, combo: model.bindings[action.id], display: model.display,
                                           onRecord: { model.record($0, for: action.id) },
                                           bringForward: model.bringForwardForRecording,
                                           onHotkeysAside: model.setHotkeysAside,
                                           window: { model.settingsWindow })
                            ForEach(model.warnings(for: action.id)) { warning in
                                Text(warning.text)
                                    .font(.caption)
                                    .foregroundStyle(warning.isError ? Color.red : Color.orange)
                                    .multilineTextAlignment(.trailing)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            } footer: {
                Text("A shortcut works in every app. Use ⌘, ⌃ or ⌥ with the key.")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
        // The person may have changed macOS's own shortcuts in System Settings and come back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}
