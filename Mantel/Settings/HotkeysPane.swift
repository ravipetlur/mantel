import AppKit
import MKCommands
import MKCore
import MKLayout
import MKMenuBar
import MKSearch
import SwiftUI

/// A line under a shortcut's field: a clash to know about, or a reason the shortcut won't work.
struct HotkeyWarning: Identifiable, Equatable {
    let text: String
    /// Whether the shortcut won't work at all (red), rather than may not (orange).
    let isError: Bool

    var id: String { text }
}

/// What the Icons section lists, worked out once for a draw: the rows, the icons that can be added, and what each icon is called.
struct IconHotkeySection {
    let rows: [IconHotkeyRow]
    let addable: [IconSearchEntry]
    /// By icon, for every row and every icon that can be added: what a warning calls the icon.
    let names: [ItemID: String]
}

/// What the Hotkeys pane shows and does: the bindings and the macOS shortcuts they are checked against, kept in step with
/// the coordinator, which saves and registers them.
///
/// **An icon's shortcut is saved with what it does** (`AppCoordinator.setIconShortcut`), and taken away with it: a shortcut that has no
/// action isn't registered. An icon that was added but has no shortcut yet is only in `pending`, with the action picked for it, and is
/// gone when the pane is.
@Observable
final class HotkeysModel {
    private let coordinator: AppCoordinator
    private(set) var bindings: [HotkeyID: KeyCombo]
    private(set) var failures: [HotkeyID: HotkeyRegistrationError]
    private(set) var systemShortcuts: [SymbolicHotkey] = []
    /// The actions whose last recorded shortcut wasn't kept, with why, so that the reason stays under the field.
    private var refused: [HotkeyID: String] = [:]
    private let translator = LiveKeyTranslator()
    private let identities: AppIdentities
    /// What `icons.json` says each icon's shortcut does, as the coordinator has it.
    private(set) var preferences: IconPreferences
    /// The icons that were added and have no shortcut yet, with the action picked for each.
    private var pending: [ItemID: IconHotkeyAction] = [:]

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        identities = AppIdentities(runningApps: coordinator.runningApps)
        bindings = coordinator.hotkeyBindings.bindings
        failures = coordinator.hotkeyFailures
        preferences = coordinator.iconPreferences
    }

    /// Reads everything again: macOS's shortcuts change in System Settings while Mantel runs.
    func refresh() {
        bindings = coordinator.hotkeyBindings.bindings
        failures = coordinator.hotkeyFailures
        preferences = coordinator.iconPreferences
        systemShortcuts = SystemShortcuts.read()
        // A shortcut written by hand without an action would do nothing: it is given the action its row shows.
        // All in one write: separate ones would each be made on the file as it was.
        let missing = icons().rows.filter { $0.hasBinding && !$0.hasStoredAction }
        if !missing.isEmpty {
            let actions = Dictionary(missing.map { ($0.item, $0.action) }, uniquingKeysWith: { first, _ in first })
            Task {
                await coordinator.setIconActions(actions)
                preferences = coordinator.iconPreferences
            }
        }
    }

    // MARK: Icons

    /// The Icons section as it is now: from what the menu bar last said, so that it changes when that does.
    func icons() -> IconHotkeySection {
        // Every record, for the rows and the names: a shortcut that is already on an icon the app no longer has still shows, with its
        // app's name, and can be taken away. The icons that can be added are only the ones that can be reached now.
        var entries: [IconSearchEntry] = []
        var reachable: [IconSearchEntry] = []
        if let state = coordinator.menuBar?.model.state {
            let names = identities.names(for: LayoutRows.appIDs(inventory: state.inventory, sections: state.sections, lists: state.lists))
            entries = IconSearchEntries.build(inventory: state.inventory, sections: state.sections, preferences: preferences, names: names)
            reachable = IconSearchEntries.build(inventory: state.inventory, sections: state.sections, preferences: preferences, names: names,
                                                running: Set(coordinator.runningApps.all.compactMap(\.bundleID)), stale: state.staleRecords)
        }
        let rows = IconHotkeyRows.rows(bindings: bindings, preferences: preferences, entries: entries, pending: pending,
                                       fallbackName: { identities.name(for: $0.bundleID) })
        let addable = IconHotkeyRows.addable(entries: reachable, rows: rows)
        let titles = IconHotkeyRows.displayNames(for: entries)
        return IconHotkeySection(rows: rows, addable: addable, names: IconHotkeyRows.names(rows: rows, addable: addable, titles: titles))
    }

    /// The picture of an icon, for a bar that looks like this window.
    func image(for item: ItemID, dark: Bool) -> NSImage? {
        coordinator.menuBar?.itemImages.image(for: item, appearance: dark ? .dark : .light)
    }

    /// Whether the option click is offered as what a shortcut does: it isn't while it arrives as a plain left click.
    var optionClickWorks: Bool { ClickRouteRules.measured.postedOptionWorks }

    func addIcon(_ item: ItemID) {
        pending[item] = .show
    }

    /// Changes what an icon's shortcut does. A row with no shortcut yet only remembers it, until the shortcut is recorded.
    func setAction(_ action: IconHotkeyAction, for row: IconHotkeyRow) {
        guard row.hasBinding else {
            pending[row.item] = action
            return
        }
        Task {
            await coordinator.setIconAction(action, for: row.item)
            refresh()
        }
    }

    /// Takes an icon's row away, with its shortcut and what it did.
    func removeIcon(_ row: IconHotkeyRow) {
        pending[row.item] = nil
        refused[.icon(row.item)] = nil
        Task {
            await coordinator.removeIconShortcut(for: row.item)
            refresh()
        }
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
            if let item = id.iconItem {
                // The shortcut and what it did are taken away together; the row stays, with what it did, for a new shortcut.
                pending[item] = icons().rows.first { $0.item == item }?.action ?? .show
                refused[id] = nil
                Task {
                    await coordinator.removeIconShortcut(for: item)
                    refresh()
                }
                return
            }
            note(coordinator.setHotkey(nil, for: id), for: id)
            return
        }
        let clashes = ClashDetector.clashes(for: combo, assigning: id, mantel: bindings, system: systemShortcuts)
        if clashes.contains(where: \.preventsSaving) {
            refused[id] = HotkeyClash.noModifier.message(actionTitle: HotkeyAction.title(for:))
            return
        }
        if let item = id.iconItem {
            // Saved with what it does, and registered with it.
            let action = icons().rows.first { $0.item == item }?.action ?? .show
            Task {
                note(await coordinator.setIconShortcut(combo, action: action, for: item), for: id)
                refresh()
            }
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
    func warnings(for id: HotkeyID, iconNames: [ItemID: String] = [:]) -> [HotkeyWarning] {
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
            add(clash.message(actionTitle: { HotkeyTitles.title(for: $0, iconName: { iconNames[$0] }) }), to: &lines)
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

/// Settings › Hotkeys: each action Mantel can be told to do from any app, with the field its shortcut is recorded in, and the icons that
/// have a shortcut of their own.
struct HotkeysPane: View {
    @State private var model: HotkeysModel
    @Environment(\.colorScheme) private var colorScheme

    init(coordinator: AppCoordinator) {
        // Only keeps the coordinator: what the model reads is read again when the pane appears.
        _model = State(initialValue: HotkeysModel(coordinator: coordinator))
    }

    var body: some View {
        let icons = model.icons()
        Form {
            Section {
                ForEach(HotkeyAction.all) { action in
                    // Not a `LabeledContent`: it links the title to the content, and SwiftUI's accessibility then never finishes resolving
                    // a field that is recording (a stack overflow when an assistive tool reads the window). A title and what it names, side
                    // by side, look the same.
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(action.title)
                        Spacer(minLength: 12)
                        field(title: action.title, id: action.id, icons: icons)
                    }
                }
            } footer: {
                Text("A shortcut works in every app. Use ⌘, ⌃ or ⌥ with the key.")
            }
            iconsSection(icons)
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
        // The person may have changed macOS's own shortcuts in System Settings and come back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    /// The recorder for one shortcut, with what is under it.
    private func field(title: String, id: HotkeyID, icons: IconHotkeySection) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HotkeyRecorder(title: title, combo: model.bindings[id], display: model.display,
                           onRecord: { model.record($0, for: id) },
                           bringForward: model.bringForwardForRecording,
                           onHotkeysAside: model.setHotkeysAside,
                           window: { model.settingsWindow })
            ForEach(model.warnings(for: id, iconNames: icons.names)) { warning in
                Text(warning.text)
                    .font(.caption)
                    .foregroundStyle(warning.isError ? Color.red : Color.orange)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Icons

    private func iconsSection(_ icons: IconHotkeySection) -> some View {
        Section {
            ForEach(icons.rows) { row in
                iconRow(row, icons: icons)
            }
            Menu("Add an icon…") {
                ForEach(icons.addable, id: \.item) { entry in
                    Button(icons.names[entry.item] ?? entry.title) { model.addIcon(entry.item) }
                }
            }
            .disabled(icons.addable.isEmpty)
        } header: {
            Text("Icons")
        } footer: {
            Text("Shows an icon without moving it to another section, and can click it.")
        }
    }

    /// An icon's picture and name, what its shortcut does, the shortcut, and the button that takes it away. (An `HStack`, as above.)
    private func iconRow(_ row: IconHotkeyRow, icons: IconHotkeySection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let image = model.image(for: row.item, dark: colorScheme == .dark) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            Picker(row.name, selection: Binding(
                get: { row.action.title },
                set: { title in
                    if let action = IconHotkeyAction.allChoices.first(where: { $0.title == title }) { model.setAction(action, for: row) }
                })) {
                ForEach(IconHotkeyAction.choices(keeping: row.action, optionWorks: model.optionClickWorks), id: \.title) { choice in
                    Text(choice.title).tag(choice.title)
                }
            }
            .labelsHidden()
            .fixedSize()
            field(title: HotkeyTitles.title(for: .icon(row.item), iconName: { _ in row.name }) ?? row.name, id: .icon(row.item), icons: icons)
            Button {
                model.removeIcon(row)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove shortcut for \(row.name)")
        }
    }
}
