import AppKit
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
    /// The actions whose last recorded shortcut was refused for want of a modifier, so that the reason stays under the field.
    private var refused: Set<HotkeyID> = []
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

    func display(_ combo: KeyCombo) -> String {
        KeyNames.display(combo, translator: translator)
    }

    /// A shortcut recorded for `id`, or nil for one cleared. Fn is left out of what is kept, as it is of what is registered.
    /// A combo with no ⌘, ⌃ or ⌥ isn't kept: the shortcut stays as it was, and the reason shows under the field. Every other
    /// clash is shown and the shortcut is kept.
    func record(_ combo: KeyCombo?, for id: HotkeyID) {
        defer { refresh() }
        guard let combo = combo?.withoutFunction else {
            refused.remove(id)
            coordinator.setHotkey(nil, for: id)
            return
        }
        let clashes = ClashDetector.clashes(for: combo, assigning: id, mantel: bindings, system: systemShortcuts)
        if clashes.contains(where: \.preventsSaving) {
            refused.insert(id)
            return
        }
        refused.remove(id)
        coordinator.setHotkey(combo, for: id)
    }

    /// Whether a shortcut is being recorded, which puts every hotkey aside until it is done.
    func setListening(_ listening: Bool) {
        coordinator.setHotkeysSuspended(listening)
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

        if refused.contains(id) {
            add(HotkeyClash.noModifier.message(actionTitle: HotkeyAction.title(for:)), to: &lines)
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
                    LabeledContent(action.title) {
                        VStack(alignment: .trailing, spacing: 4) {
                            HotkeyRecorder(title: action.title, combo: model.bindings[action.id], display: model.display,
                                           onRecord: { model.record($0, for: action.id) },
                                           onListeningChange: model.setListening)
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
