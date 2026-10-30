import AppKit
import MKCore
import MKLayout
import MKMenuBar
import SwiftUI

/// Settings › Layout: where each icon is, as a row of tokens for each section and group that can be dragged about, what can be added to
/// the menu bar, the selected icon's fields, the options, and the lists that say what can't be changed.
///
/// - **What it draws is the menu bar model's** (`MenuBarModel`, the session's last state): nothing here reads the menu bar or polls.
///   What the strips hold, and what a drop does, is `LayoutEditorModel`'s; the rows of the lists are `LayoutRows`'s; what the banner says
///   is `LayoutBannerModel`'s.
/// - **A change goes to the menu bar controller**, which hands it to the session on the queue of its events. Every change is shown at
///   once (`PendingMoves`) until the model has it, so that the strips show the list the session will have when the next drop is made. A
///   drop goes as the tokens it lands between, and the session works out the place on its own model.
/// - **Drag and drop:** each strip is one view that takes drops itself (`IconStrip`): a section of a grouped form isn't a view that can.
///   What is being dragged is `dragging`, set when a drag starts, so that a strip can forbid, while the pointer is over it, a drop the
///   model would refuse or decline. Every drag has its menu equivalent: a token's "Move Left", "Move Right" and "Move to", and the
///   palette's "Add".
struct LayoutPane: View {
    let coordinator: AppCoordinator
    @State private var identities: AppIdentities
    /// What is being dragged (a token or a palette tile), from the start of the drag until it is dropped.
    @State private var dragging: EditorDrop?
    /// The changes asked for that the session hasn't made yet.
    @State private var pending = PendingMoves()
    /// The token that was clicked (`StripToken.id`).
    @State private var selection: String?
    /// What the last refused drop said, while the banner flashes it.
    @State private var refusal: String?
    @State private var refusalCount = 0
    /// The section a palette item was put at the end of, for want of the layout file.
    @State private var addedAtTheEnd: MenuBarSection?
    @State private var isConfirmingRestore = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _identities = State(initialValue: AppIdentities(runningApps: coordinator.runningApps))
    }

    var body: some View {
        let menuBar = coordinator.menuBar
        let state = menuBar?.model.state
        Form {
            if let menuBar, let state {
                content(menuBar: menuBar, state: state)
            } else {
                Section {
                    Text(LayoutCopy.notReadYet).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // The session has made some of what was asked: those moves are the state now, and the others are still shown as asked.
        .onChange(of: state?.sections) { _, sections in
            if let sections, let inventory = state?.inventory { pending.settle(against: sections, inventory: inventory) }
        }
    }

    // MARK: The sections

    @Environment(\.colorScheme) private var colorScheme

    /// What every strip and the selected icon are drawn from, and decided by.
    private struct Editor {
        let state: MenuBarState
        let sections: SectionModel
        let strips: [Strip]
        let names: [String: String]
        let cantReorder: Set<String>
        let running: Set<String>
        let canReorder: Bool
        let context: StripContext

        /// What a drop is decided from: what `strips` was made from.
        var drops: LayoutEditorModel.DropContext {
            .init(sections: sections, canReorder: canReorder, cantReorder: cantReorder, inventory: state.inventory, running: running,
                  stale: state.staleRecords)
        }
    }

    @ViewBuilder
    private func content(menuBar: MenuBarController, state: MenuBarState) -> some View {
        let settings = coordinator.settingsModel.settings
        // What is shown is the model's, with the moves that are being made: an icon is where it is going.
        let sections = pending.applied(to: state.sections, inventory: state.inventory)
        let names = identities.names(for: LayoutRows.appIDs(inventory: state.inventory, sections: sections, lists: state.lists))
        let running = Set(coordinator.runningApps.all.compactMap(\.bundleID))
        let cantReorder = LayoutRows.cantReorderApps(lists: state.lists)
        let rows = Dictionary(
            LayoutRows.apps(inventory: state.inventory, sections: sections, names: names, turnedOff: state.lists.turnedOff,
                            unattached: state.unattachedApps, allowlistInUse: state.engine.kind == .allowlist)
                .values.joined().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let strips = LayoutEditorModel.strips(sections: sections, inventory: state.inventory, running: running, widths: state.widths,
                                              stale: state.staleRecords)
        let context = StripContext(sections: sections, names: names, cantReorder: cantReorder, rows: rows, images: menuBar.itemImages,
                                   appearance: colorScheme == .dark ? .dark : .light, widths: state.widths,
                                   ownImages: coordinator.paths.ownImages)
        let editor = Editor(state: state, sections: sections, strips: strips, names: names, cantReorder: cantReorder, running: running,
                            canReorder: state.layout?.availability.allowsReordering ?? false, context: context)

        LayoutBanner(lines: LayoutBannerModel.lines(status: state.layout, addedAtTheEndOf: addedAtTheEnd, refusal: refusal,
                                                    dragging: dragging != nil),
                     flashing: refusal, grantAccess: grantAccess)

        ForEach(MenuBarSection.allCases, id: \.self) { section in
            Section {
                if let strip = strips.first(where: { $0.id == .section(section) }) {
                    stripView(strip, title: section.title, editor: editor, menuBar: menuBar)
                }
            } header: {
                Text(section.title)
            } footer: {
                Text(LayoutCopy.footer(for: section))
            }
        }

        groupedSection(editor: editor, menuBar: menuBar)
        PaletteSection(
            add: { item, section in addToEnd(.palette(item), of: .section(section), editor: editor, menuBar: menuBar) },
            drag: startDrag)
        selectedSection(editor: editor, menuBar: menuBar)
        optionsSection(editor: editor, settings: settings, menuBar: menuBar)

        systemSection(menuBar: menuBar, state: state, sections: sections, allowClock: settings.hiding.allowHidingClockAndControlCenter)
        readOnlySection(menuBar: menuBar, state: state, sections: sections, names: names,
                        allowClock: settings.hiding.allowHidingClockAndControlCenter)
    }

    // MARK: Strips

    private func stripView(_ strip: Strip, title: String, editor: Editor, menuBar: MenuBarController) -> some View {
        IconStrip(
            strip: strip, title: title, context: editor.context, selection: selection,
            targets: { token in targets(for: token, editor: editor).filter { $0.strip != strip.id } },
            select: { selection = $0.id },
            dragging: dragging,
            landing: { drop, place in LayoutEditorModel.landingPlace(for: drop, onto: strip.id, near: place, in: editor.drops) },
            refusal: { drop, place in LayoutEditorModel.refusal(for: drop, onto: strip.id, near: place, in: editor.drops) },
            refuse: { text in flash(text, status: editor.state.layout) },
            drag: startDrag,
            drop: { drop, place in perform(drop, onto: strip.id, at: place, editor: editor, menuBar: menuBar) },
            move: { token, target in moveToken(token, from: strip.id, to: target, editor: editor, menuBar: menuBar) },
            canMoveWithin: { token, direction in
                LayoutEditorModel.neighbourPlace(of: token, toward: direction, in: strip, context: editor.drops) != nil
            },
            moveWithin: { token, direction in
                guard let place = LayoutEditorModel.neighbourPlace(of: token, toward: direction, in: strip, context: editor.drops) else { return }
                perform(.token(token, from: strip.id), onto: strip.id, at: place, editor: editor, menuBar: menuBar, announcing: true)
            },
            remove: { item in remove(item, editor: editor, menuBar: menuBar) })
    }

    /// A drag starts: the strips are told what it is, and it carries a type only this app takes.
    private func startDrag(_ drop: EditorDrop) -> NSItemProvider {
        dragging = drop
        return LayoutDrag.provider()
    }

    /// The places a token can go to by menu: the sections, and for an app the groups too.
    private func targets(for token: StripToken, editor: Editor) -> [MoveTarget] {
        var targets = MenuBarSection.allCases.map { MoveTarget(strip: .section($0), title: $0.title) }
        if token.bundleID != nil {
            targets += LayoutEditorModel.groupOrder(of: editor.sections).map {
                MoveTarget(strip: .group($0), title: LayoutEditorModel.groupTitle($0, in: editor.sections))
            }
        }
        return targets
    }

    @ViewBuilder
    private func groupedSection(editor: Editor, menuBar: MenuBarController) -> some View {
        let groups = LayoutEditorModel.groupOrder(of: editor.sections)
        Section {
            if groups.isEmpty {
                Text(LayoutCopy.noGroups).foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.self) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if let look = editor.sections.groups[group]?.look {
                            OwnPicture.group(look, folder: coordinator.paths.ownImages, side: 16)
                                .frame(width: 20, height: 20)
                                .accessibilityHidden(true)
                        }
                        Text(LayoutEditorModel.groupTitle(group, in: editor.sections)).font(.headline)
                    }
                    if let strip = editor.strips.first(where: { $0.id == .group(group) }) {
                        stripView(strip, title: LayoutEditorModel.groupTitle(group, in: editor.sections), editor: editor, menuBar: menuBar)
                    }
                }
            }
        } header: {
            Text(LayoutCopy.groupedHeader)
        } footer: {
            Text(LayoutCopy.groupedFooter)
        }
    }

    // MARK: What a drop does

    /// What was dropped on a strip (or done by a menu, which is a drop at a place) is decided by the model and handed to the session as
    /// the tokens it lands between. A refusal says so in the banner, flashing, and for a menu (a VoiceOver action is one) it is also
    /// announced; there is no alert. A drop the model declines does nothing.
    private func perform(_ drop: EditorDrop, onto strip: StripID, at index: Int, editor: Editor, menuBar: MenuBarController,
                         announcing: Bool = false) {
        dragging = nil
        // A token that left its strip while it was being dragged (its app quit, say) is no drop.
        guard let drop = LayoutEditorModel.current(drop, in: editor.strips) else { return }
        let operation = LayoutEditorModel.operation(for: drop, onto: strip, at: index, in: editor.drops)
        switch operation {
        case .refused(let text):
            flash(text, status: editor.state.layout, announcing: announcing)
            return
        case .noChange:
            return
        case .addSpacer(let section, _), .addGroup(let section, _):
            addedAtTheEnd = editor.canReorder ? nil : section
        case .insert, .marker, .moveToGroup:
            addedAtTheEnd = nil
        }
        // Shown at its place at once, until the session has made it.
        let request = LayoutEditorModel.request(for: drop, onto: strip, at: index, in: editor.drops)
        pending.ask(.drop(request), on: editor.sections, inventory: editor.state.inventory)
        refusal = nil
        menuBar.apply(request)
    }

    /// The menus' "Move to" and "Add": the same as dropping at the end of the strip (before the marker, when it is last: nothing can
    /// be put after it).
    private func addToEnd(_ drop: EditorDrop, of target: StripID, editor: Editor, menuBar: MenuBarController) {
        let end = LayoutEditorModel.endPlace(for: drop, onto: target, in: editor.drops)
        perform(drop, onto: target, at: end, editor: editor, menuBar: menuBar, announcing: true)
    }

    /// The menu's "Move to": the same as dropping the token at the end of the other strip.
    private func moveToken(_ token: StripToken, from source: StripID, to target: StripID, editor: Editor, menuBar: MenuBarController) {
        addToEnd(.token(token, from: source), of: target, editor: editor, menuBar: menuBar)
    }

    private func remove(_ item: ItemID, editor: Editor, menuBar: MenuBarController) {
        selection = nil
        pending.ask(.remove(item), on: editor.sections, inventory: editor.state.inventory)
        menuBar.remove(ownItem: item)
    }

    /// The banner flashes what a drop was refused for, for two seconds. A refusal from a menu or a VoiceOver action is said aloud too: the
    /// flash is only seen.
    /// A drop that is refused for want of the file, when the file is given and reordering is broken, flashes the broken line
    /// (`LayoutBannerModel.flashed`).
    private func flash(_ text: String, status: LayoutStatus? = nil, announcing: Bool = false) {
        let text = LayoutBannerModel.flashed(text, status: status)
        if announcing { AccessibilityNotification.Announcement(text).post() }
        refusal = text
        refusalCount += 1
        let count = refusalCount
        Task {
            try? await Task.sleep(for: .seconds(2))
            if refusalCount == count { refusal = nil }
        }
    }

    /// The same file panel as Settings › Permissions; what depends on the file is asked again once it is kept.
    private func grantAccess() {
        let grants = coordinator.grants
        Task {
            if await FileGrantPanel.choose(.menuBarLayout, grants: grants) { coordinator.permissionsChanged() }
        }
    }

    // MARK: The selected icon

    @ViewBuilder
    private func selectedSection(editor: Editor, menuBar: MenuBarController) -> some View {
        if let selection, let found = editor.strips.lazy.compactMap({ strip in
            strip.tokens.first { $0.token.id == selection }.map { (strip.id, $0.token) }
        }).first {
            SelectedIconSection(
                token: found.1, strip: found.0, context: editor.context, targets: targets(for: found.1, editor: editor),
                store: coordinator.store, preferences: coordinator.iconPreferencesWriter,
                saved: { coordinator.iconPreferencesChanged($0) },
                shortcut: { items in
                    HotkeyRegistrationPlan.shortcut(ofItems: items, bindings: coordinator.hotkeyBindings.bindings, preferences: coordinator.iconPreferences,
                                                    failed: Set(coordinator.hotkeyFailures.keys))
                        .map { KeyNames.display($0, translator: LiveKeyTranslator()) }
                },
                editInHotkeys: { coordinator.openSettings(.hotkeys) },
                moveTo: { target in moveToken(found.1, from: found.0, to: target, editor: editor, menuBar: menuBar) },
                update: { menuBar.update(spacer: $0) }, updateGroup: { menuBar.update(group: $0) },
                remove: { remove($0, editor: editor, menuBar: menuBar) })
        }
    }

    // MARK: Options

    @ViewBuilder
    private func optionsSection(editor: Editor, settings: GeneralSettings, menuBar: MenuBarController) -> some View {
        let status = editor.state.layout
        let writerIsAvailable = status?.availability == .available
        Section {
            // Under the measured behaviour of this macOS the dots can't be kept beside the clock, and the row isn't there.
            if status?.dotsPlacementOffered == true {
                SettingsToggle(LayoutCopy.keepDotsBesideClock, isOn: Binding(
                    get: { settings.layout.dotsPlacement == .besideClock },
                    set: { value in
                        coordinator.updateGeneralSettings { $0.layout.dotsPlacement = value ? .besideClock : .betweenSections }
                    }))
                    .disabled(!writerIsAvailable)
            }
            SettingsToggle(LayoutCopy.showAllWhileDragging, isOn: Binding(
                get: { settings.layout.showAllWhileCommandDragging },
                set: { value in coordinator.updateGeneralSettings { $0.layout.showAllWhileCommandDragging = value } }))
            SettingsToggle(LayoutCopy.overflowToggle, isOn: Binding(
                get: { settings.hiding.automaticOverflow },
                set: { value in coordinator.updateGeneralSettings { $0.hiding.automaticOverflow = value } }))
            HStack {
                Button(LayoutCopy.recaptureIcons) { menuBar.recaptureIcons() }
                Button(LayoutCopy.restoreOriginal) { isConfirmingRestore = true }
                    .disabled(status?.hasKeptChanges != true)
            }
        } header: {
            Text(LayoutCopy.optionsHeader)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if status?.dotsPlacementOffered == true { Text(LayoutCopy.keepDotsFooter) }
                Text(LayoutCopy.overflowFooter)
            }
        }
        .alert(LayoutCopy.restoreTitle, isPresented: $isConfirmingRestore) {
            Button(LayoutCopy.restore) { restore(status: status, menuBar: menuBar) }
            Button(LayoutCopy.cancel, role: .cancel) {}
        } message: {
            Text(LayoutCopy.restoreText)
        }
    }

    /// Puts the original order back. A restore that doesn't happen says why in the banner: for a hold, the hold's reason (the answer to a
    /// restore during one is the generic failure).
    private func restore(status: LayoutStatus?, menuBar: MenuBarController) {
        Task {
            if case .failure(let error) = await menuBar.restoreOriginalLayout() {
                flash(LayoutBannerModel.restoreFailure(error, status: status))
            }
        }
    }

    @ViewBuilder
    private func systemSection(menuBar: MenuBarController, state: MenuBarState, sections: SectionModel, allowClock: Bool) -> some View {
        let rows = LayoutRows.system(inventory: state.inventory, sections: sections, allowClockAndControlCenter: allowClock)
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    Picker(row.title, selection: Binding(
                        get: { row.section },
                        set: { section in
                            pending.ask(.system(module: row.id, section), on: sections, inventory: state.inventory)
                            menuBar.move(item: .system(row.id), to: section)
                        })
                    ) {
                        ForEach(MenuBarSection.allCases, id: \.self) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .disabled(!row.canChange)
                }
            } header: {
                Text(LayoutCopy.systemIconsHeader)
            } footer: {
                Text(LayoutCopy.systemIconsFooter)
            }
        }
    }

    // MARK: What can't be changed

    @ViewBuilder
    private func readOnlySection(menuBar: MenuBarController, state: MenuBarState, sections: SectionModel, names: [String: String],
                                 allowClock: Bool) -> some View {
        let rows = LayoutRows.readOnly(lists: state.lists, inventory: state.inventory, names: names, allowClockAndControlCenter: allowClock)
        Section(LayoutCopy.readOnlyHeader) {
            listBlock(LayoutCopy.cantMoveTitle, caption: LayoutCopy.cantMoveCaption, rows: rows.cantMove)
            listBlock(LayoutCopy.cantReorderTitle, caption: LayoutCopy.cantReorderCaption, rows: rows.cantReorder)
            switch rows.turnedOff {
            case .apps(let apps):
                listBlock(LayoutCopy.turnedOffTitle, caption: nil, rows: apps)
            case .unavailable(let reason):
                // Why the list can't be said, in the place of the names.
                headingRow(LayoutCopy.turnedOffTitle, caption: nil)
                Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            listBlock(LayoutCopy.missingTitle, caption: LayoutCopy.missingCaption, rows: rows.missing) { bundleID in
                pending.ask(.forget(bundleID: bundleID), on: sections, inventory: state.inventory)
                menuBar.forget(app: bundleID)
            }
            listBlock(LayoutCopy.overflowTitle, caption: LayoutCopy.overflowCaption, rows: rows.overflow)
            listBlock(LayoutCopy.cantHideYetTitle, caption: LayoutCopy.cantHideYetCaption, rows: rows.cantHideYet)
        }
    }

    /// A list's heading and what it means, then its rows (each with a Forget button when `forget` is given), or "None.".
    @ViewBuilder
    private func listBlock(_ title: String, caption: String?, rows: [NamedRow], forget: ((String) -> Void)? = nil) -> some View {
        headingRow(title, caption: caption)
        if rows.isEmpty {
            Text(LayoutCopy.none).foregroundStyle(.secondary)
        } else {
            ForEach(rows) { row in
                HStack {
                    Text(row.name).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let forget {
                        Button(LayoutCopy.forget) { forget(row.id) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func headingRow(_ title: String, caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
