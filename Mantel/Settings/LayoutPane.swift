import AppKit
import MKCore
import MKLayout
import MKMenuBar
import SwiftUI

/// Settings › Layout: where each app's icons are (Shown, Hidden, Always Hidden), and the lists that say what can't be changed.
///
/// - **What it draws is the menu bar model's** (`MenuBarModel`, the session's last state): nothing here reads the menu bar or polls.
///   What the rows are, and what a drop moves, is `LayoutRows`'s.
/// - **A move goes to the menu bar controller**, which hands it to the session on the queue of its events. It shows when the session has
///   made it, so a move that is asked for is shown at once (`PendingMoves`) until the model says the icon is there.
/// - **Drag and drop:** each row can be dragged (it is its bundle ID), and each row of a section, or its empty line, takes a drop that
///   moves the app to that section. The drop is on the section's content: a drop destination on the section itself isn't a view in a
///   grouped form. The section is lit while any of its rows is being dragged over (a set of the rows that are, so that moving from one
///   row to the next never puts it out).
struct LayoutPane: View {
    let coordinator: AppCoordinator
    @State private var identities: AppIdentities
    /// The rows that are being dragged over, each as its section and itself (`marker`).
    @State private var targetedRows: Set<String> = []
    /// The moves asked for that the session hasn't made yet.
    @State private var pending = PendingMoves()

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
            if let sections { pending.settle(against: sections) }
        }
    }

    // MARK: The sections

    @ViewBuilder
    private func content(menuBar: MenuBarController, state: MenuBarState) -> some View {
        let settings = coordinator.settingsModel.settings
        // What is shown is the model's, with the moves that are being made: an icon is where it is going.
        let sections = pending.applied(to: state.sections)
        let names = identities.names(for: LayoutRows.appIDs(inventory: state.inventory, sections: sections, lists: state.lists))
        let apps = LayoutRows.apps(inventory: state.inventory, sections: sections, names: names, turnedOff: state.lists.turnedOff)

        ForEach(MenuBarSection.allCases, id: \.self) { section in
            appSection(section, rows: apps[section] ?? [], all: apps, menuBar: menuBar)
        }

        Section {
            Picker(LayoutCopy.newIconsPicker, selection: Binding(
                get: { sections.newItems },
                set: { section in
                    pending.setNewItems(section)
                    menuBar.setNewItemsSection(section)
                })
            ) {
                ForEach(MenuBarSection.allCases, id: \.self) { section in
                    Text(section.title).tag(section)
                }
            }
            SettingsToggle(LayoutCopy.overflowToggle, isOn: Binding(
                get: { settings.hiding.automaticOverflow },
                set: { value in coordinator.updateGeneralSettings { $0.hiding.automaticOverflow = value } }))
        } header: {
            Text(LayoutCopy.newIconsHeader)
        } footer: {
            Text(LayoutCopy.overflowFooter)
        }

        systemSection(menuBar: menuBar, state: state, sections: sections, allowClock: settings.hiding.allowHidingClockAndControlCenter)
        readOnlySection(menuBar: menuBar, state: state, names: names, allowClock: settings.hiding.allowHidingClockAndControlCenter)
    }

    /// One of Shown, Hidden and Always Hidden: its apps, or what to do when it has none. A drop on any of its rows (or on its empty line)
    /// moves the app here.
    private func appSection(_ section: MenuBarSection, rows: [AppRow], all: [MenuBarSection: [AppRow]],
                            menuBar: MenuBarController) -> some View {
        Section {
            Group {
                if rows.isEmpty {
                    droppable(
                        Text(LayoutCopy.emptySection)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle()),
                        in: section, row: "empty", all: all, menuBar: menuBar)
                } else {
                    ForEach(rows) { row in
                        droppable(
                            AppRowView(row: row, section: section, icon: identities.icon(for: row.id)) { target in
                                moveApp(row.id, to: target, menuBar: menuBar)
                            },
                            in: section, row: row.id, all: all, menuBar: menuBar)
                    }
                }
            }
        } header: {
            Text(section.title)
        } footer: {
            Text(LayoutCopy.footer(for: section))
        }
    }

    /// `content` as a place to drop an app on `section`. The section is lit while any of its rows is dragged over: each row says when
    /// it is, by its own marker.
    private func droppable(_ content: some View, in section: MenuBarSection, row: String, all: [MenuBarSection: [AppRow]],
                           menuBar: MenuBarController) -> some View {
        let marker = Self.marker(section, row)
        return content
            .listRowBackground(isLit(section) ? Color.accentColor.opacity(0.14) : nil)
            .dropDestination(for: String.self) { dropped, _ in
                // The drag is over: no row of this section is dragged over any more, whatever the rows said last.
                targetedRows = targetedRows.filter { !$0.hasPrefix(Self.marker(section, "")) }
                let moving = LayoutRows.droppedApps(dropped, into: section, rows: all)
                for bundleID in moving { moveApp(bundleID, to: section, menuBar: menuBar) }
                return !moving.isEmpty
            } isTargeted: { isOver in
                if isOver {
                    targetedRows.insert(marker)
                } else {
                    targetedRows.remove(marker)
                }
            }
            // A row can leave the hierarchy in the middle of a drag (a read moved its app), and would never say that the drag left it.
            .onDisappear { targetedRows.remove(marker) }
    }

    private static func marker(_ section: MenuBarSection, _ row: String) -> String {
        "\(section.rawValue)/\(row)"
    }

    private func isLit(_ section: MenuBarSection) -> Bool {
        let prefix = Self.marker(section, "")
        return targetedRows.contains { $0.hasPrefix(prefix) }
    }

    /// An app is moved: shown there at once, and handed to the menu bar.
    private func moveApp(_ bundleID: String, to section: MenuBarSection, menuBar: MenuBarController) {
        pending.move(app: bundleID, to: section)
        menuBar.move(app: bundleID, to: section)
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
                            pending.move(systemItem: row.id, to: section)
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
    private func readOnlySection(menuBar: MenuBarController, state: MenuBarState, names: [String: String], allowClock: Bool) -> some View {
        let rows = LayoutRows.readOnly(lists: state.lists, inventory: state.inventory, names: names, allowClockAndControlCenter: allowClock)
        Section(LayoutCopy.readOnlyHeader) {
            listBlock(LayoutCopy.cantMoveTitle, caption: LayoutCopy.cantMoveCaption, rows: rows.cantMove)
            switch rows.turnedOff {
            case .apps(let apps):
                listBlock(LayoutCopy.turnedOffTitle, caption: nil, rows: apps)
            case .unavailable(let reason):
                // Why the list can't be said, in the place of the names.
                headingRow(LayoutCopy.turnedOffTitle, caption: nil)
                Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            listBlock(LayoutCopy.missingTitle, caption: LayoutCopy.missingCaption, rows: rows.missing) { bundleID in
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

/// An app in a section: its icon and name, how many icons it has (or that it isn't answering, or is turned off in System Settings),
/// whether Mantel put it here, and the menu that moves it.
///
/// Every column has one width on every row, so the rows line up whatever an app is called or has: the count, the room for the capsule
/// (empty on rows that don't have one) and the menu.
private struct AppRowView: View {
    let row: AppRow
    let section: MenuBarSection
    let icon: NSImage
    let move: (MenuBarSection) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(row.statusText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(row.needsAttention ? Color.orange : Color.secondary)
                .lineLimit(1)
                .frame(width: 128, alignment: .trailing)
                .help(row.helpText)
            autoSlot
                .frame(width: 44, alignment: .center)
            Menu(LayoutCopy.moveTo) {
                ForEach(MenuBarSection.allCases, id: \.self) { target in
                    Button(target.title) { move(target) }
                        .disabled(target == section)
                }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 92, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .draggable(row.id)
    }

    @ViewBuilder
    private var autoSlot: some View {
        if row.isAuto {
            Text(LayoutCopy.auto)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.secondary.opacity(0.18)))
                // The help is the tooltip and what the accessibility tools get as its help. (No `.accessibilityLabel` on a `Text`: see
                // `HotkeysPane`, where one made SwiftUI's accessibility loop.)
                .help(LayoutCopy.autoHelp)
        } else {
            Color.clear.frame(height: 1)
        }
    }
}
