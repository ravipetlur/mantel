import AppKit
import MKCore
import MKLayout
import MKMenuBar

/// The second bar: the icons that a reveal brings, in a panel of Mantel's own under the menu bar.
///
/// - **Opening** builds the entries from the state the session last published (the Hidden icons, or those and Always Hidden's and the
///   groups' when the level is everything), lays them out for the screen's width less the margins, puts the panel under its anchor, and
///   brings it forward. It takes the keyboard only when asked, and never makes Mantel the active app.
/// - **It follows the state.** What it lists is rebuilt whenever the session publishes: automatic overflow can move a Shown app to Hidden
///   while the bar is open.
/// - **A cell** is clicked through the one click driver (`PanelCellClicks`), in this order: the icon is brought to the bar, the panel
///   closes, the click is sent. The reveal then collapses, and the icon stays out for as long as its click holds it.
/// - **It stays where its item is.** The anchor is kept as what it is under (the dot) and found again in the newest read of the bar.
/// - **Closing** tells the panels (and so the reveal) why.
@MainActor
final class SecondBarController {
    private let environment: PanelEnvironment
    private unowned let panels: MantelPanels
    private lazy var host = BarPanelHost(
        images: environment.images, layout: environment.layout, ownItemFrames: { [environment] in environment.ownItemFrames() },
        clickInFlight: { [environment] in environment.clicker.isClickInFlight }, barAppearance: environment.barAppearance,
        activate: { [weak self] cell, kind in self?.activate(cell, kind) }, closeRequested: { [weak self] reason in self?.close(reason) })
    private var level: RevealLevel = .off
    private var anchor = PanelAnchorSpec.secondBar(.rightAligned, dot: nil, pointer: .zero)
    private var display: String?
    private lazy var clicks = PanelCellClicks(environment: environment, origin: .secondBar)

    init(environment: PanelEnvironment, panels: MantelPanels) {
        self.environment = environment
        self.panels = panels
    }

    var isOpen: Bool { panels.open.contains(.secondBar) }

    /// Whether a bar for this level would list anything.
    func wouldList(level: RevealLevel) -> Bool {
        entries(level: level)?.isEmpty == false
    }

    /// Opens the bar for a reveal of this level. Nothing opens for a level that shows nothing, or while there is nothing to list; a bar
    /// that is open then is left as it is (the reveal that asked has nothing to show, and the state it shows may still).
    ///
    /// - Parameter ignoringActivationOf: the activation a takeover of the menu bar ending has caused, which isn't the person leaving
    ///   (`BarPanelHost.show`).
    func open(level: RevealLevel, anchor: PanelAnchorSpec, display: String?, makeKey: Bool, ignoringActivationOf expected: ExpectedActivation? = nil) {
        guard level != .off, let entries = entries(level: level), !entries.isEmpty else { return }
        guard let info = environment.display(named: display) else { return }
        self.level = level
        self.anchor = anchor
        self.display = info.uuid
        panels.willOpen(.secondBar)
        let placed = environment.placement(of: entries, anchor: anchor, on: info)
        host.show(entries: entries, cells: placed.cells, style: environment.style(), frame: placed.frame, makeKey: makeKey,
                  ignoringActivationOf: expected)
        panels.didOpen(.secondBar)
    }

    func close(_ reason: PanelCloseReason) {
        guard isOpen else { return }
        host.hide()
        panels.didClose(.secondBar, reason)
    }

    /// Lists again from the last state, in the same place: the state changed, or the look did.
    func refresh() {
        guard isOpen, let info = environment.display(named: display), let entries = entries(level: level) else { return }
        guard !entries.isEmpty else {
            // Nothing is left to list (the apps quit, or moved to Shown): the bar goes, and the reveal with it.
            close(.escape)
            return
        }
        let placed = environment.placement(of: entries, anchor: anchor, on: info)
        host.update(entries: entries, cells: placed.cells, style: environment.style(), frame: placed.frame)
    }

    private func entries(level: RevealLevel) -> [SecondBarEntry]? {
        let allow = environment.allowClockAndControlCenter()
        return environment.entries { state, running, turnedOff, names in
            SecondBarContent.entries(level: level, sections: state.sections, inventory: state.inventory, running: running, turnedOff: turnedOff,
                                     names: names, widths: state.widths, allowClockAndControlCenter: allow,
                                     stale: state.staleRecords)
        }
    }

    /// Clicks a cell: the panel closes after the icon has been brought to the bar and before the click is sent, and the reveal collapses
    /// after the click.
    private func activate(_ cell: Int, _ kind: ClickKind) {
        guard let entry = host.model.entries[safe: cell] else { return }
        clicks.activate(entry, kind: kind, display: display) { [weak self] in self?.close(.iconClick) }
    }
}

extension Array {
    /// The element at the index, or nil past the ends.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
