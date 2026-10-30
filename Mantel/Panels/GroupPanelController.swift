import AppKit
import MKCore
import MKLayout
import MKMenuBar

/// A group's panel: the icons of the apps in one group, in a panel under the group's icon on the menu bar. It is the second bar's panel
/// and cells with the group's entries (`SecondBarContent.entries(group:)`).
///
/// - **Opening one closes the second bar** and any other group panel (`PanelMath.closes`); clicking the group's icon again closes it.
///   A panel opened by a click takes the keyboard; one opened by the pointer resting on the icon doesn't (`makeKey`).
/// - **It closes** on Esc, a click outside it, an icon clicked in it, another app coming to the front, a change of displays, or (when
///   the group opens on hover) when the group's hover says so: whoever does that calls `close(_:)`.
@MainActor
final class GroupPanelController {
    private let environment: PanelEnvironment
    private unowned let panels: MantelPanels
    private lazy var host = BarPanelHost(
        images: environment.images, layout: environment.layout, ownItemFrames: { [environment] in environment.ownItemFrames() },
        clickInFlight: { [environment] in environment.clicker.isClickInFlight }, barAppearance: environment.barAppearance,
        activate: { [weak self] cell, kind in self?.activate(cell, kind) }, closeRequested: { [weak self] reason in self?.close(reason) })
    private var anchor: PanelAnchorSpec?
    private var display: String?
    private lazy var clicks = PanelCellClicks(environment: environment, origin: .groupPanel)

    /// The group whose panel is open, nil when none is.
    private(set) var openGroup: GroupID?

    /// The open panel's frame in CoreGraphics global points: what the group hover measures "off the item and the panel" against. Nil when
    /// none is open.
    var panelFrame: CGRect? {
        openGroup != nil && host.isVisible ? host.frame : nil
    }

    init(environment: PanelEnvironment, panels: MantelPanels) {
        self.environment = environment
        self.panels = panels
    }

    /// Opens the group's panel, or closes it when it is the one that is open. A group with no icon to list doesn't open.
    func toggle(_ group: GroupID, anchor: PanelAnchorSpec, display: String?, makeKey: Bool) {
        if openGroup == group {
            close(.iconClick)
            return
        }
        self.anchor = anchor
        let info = environment.display(named: display)
        self.display = info?.uuid
        guard let info, let entries = entries(of: group), !entries.isEmpty else { return }
        panels.willOpen(.group(group))
        openGroup = group
        let placed = environment.placement(of: entries, anchor: anchor, on: info)
        host.show(entries: entries, cells: placed.cells, style: environment.style(), frame: placed.frame, makeKey: makeKey)
        panels.didOpen(.group(group))
    }

    /// Gives the open panel the keyboard (without making Mantel the active app): the person clicked the icon of a panel the hover opened.
    func makeKey() {
        guard openGroup != nil else { return }
        host.makeKey()
    }

    func close(_ reason: PanelCloseReason) {
        guard let group = openGroup else { return }
        openGroup = nil
        host.hide()
        panels.didClose(.group(group), reason)
    }

    func refresh() {
        guard let group = openGroup, let anchor, let info = environment.display(named: display), let entries = entries(of: group) else { return }
        guard !entries.isEmpty else {
            close(.escape)
            return
        }
        let placed = environment.placement(of: entries, anchor: anchor, on: info)
        host.update(entries: entries, cells: placed.cells, style: environment.style(), frame: placed.frame)
    }

    private func entries(of group: GroupID) -> [SecondBarEntry]? {
        environment.entries { state, running, turnedOff, names in
            SecondBarContent.entries(group: group, sections: state.sections, inventory: state.inventory, running: running, turnedOff: turnedOff,
                                     names: names, widths: state.widths, stale: state.staleRecords)
        }
    }

    private func activate(_ cell: Int, _ kind: ClickKind) {
        guard let entry = host.model.entries[safe: cell] else { return }
        clicks.activate(entry, kind: kind, display: display) { [weak self] in self?.close(.iconClick) }
    }
}
