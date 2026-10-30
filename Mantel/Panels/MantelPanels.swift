import AppKit
import MKCore
import MKLayout
import MKMenuBar

/// What the panels need from the rest of the app. Everything that changes (the settings, the state, where the dots are) is read when it is
/// needed, so a panel is never drawn from what was true when it was made.
@MainActor
struct PanelEnvironment {
    let model: MenuBarModel
    let images: ItemImages
    let runningApps: RunningAppsSource
    /// The displays as they are now.
    let layout: () -> DisplayLayout
    let clicker: IconClickService
    /// How the second bar and the group panels look.
    let style: () -> PanelStyle
    let allowClockAndControlCenter: () -> Bool
    /// The dots' button appearance: what a panel that follows the menu bar is drawn in.
    let barAppearance: () -> NSAppearance?
    /// Where Mantel's own status items' buttons are, in CoreGraphics global points.
    let ownButtonFrames: () -> [CGRect]
    /// When the displays last changed: a read of the bar older than that is of other coordinates.
    let displaysChangedAt: () -> Date?
    /// Where the reveal is now (a stamp that moves with every change of it): taken when a cell is clicked, so that the collapse that
    /// follows the click is the collapse of the reveal that showed the cell.
    let revealStamp: () -> Int
    /// A click from a panel's cell has been sent: the reveal that showed the cell (the one the stamp was taken at) collapses, unless a
    /// newer one has come.
    let iconClickSent: (Int) -> Void
}

/// Mantel's floating panels, and which of them is open: the second bar, the group panels and the command bar are
/// never open in two places at once, so opening one closes the others (`PanelMath.closes`).
///
/// - **What is told outside:** `onChange` when a panel opens or closes (the reveal's guard on rehiding), and `onClosed` with the panel and
///   why it closed (the second bar's close, when it is the person's, puts the reveal away: `PanelMath.collapsesReveal`).
@MainActor
final class MantelPanels {
    private(set) var open: Set<MantelPanel> = []
    /// Called after a panel opened or closed.
    var onChange: () -> Void = {}
    /// Called when a panel has closed, with why.
    var onClosed: (MantelPanel, PanelCloseReason) -> Void = { _, _ in }

    private(set) lazy var secondBar = SecondBarController(environment: environment, panels: self)
    private(set) lazy var group = GroupPanelController(environment: environment, panels: self)
    let environment: PanelEnvironment
    /// Closes the command bar (set by it when it is made): another panel opening closes it, as it closes them.
    var closeCommandBar: (PanelCloseReason) -> Void = { _ in }

    init(environment: PanelEnvironment) {
        self.environment = environment
    }

    var isAnyOpen: Bool { !open.isEmpty }

    /// A panel is about to open: every other one closes.
    func willOpen(_ panel: MantelPanel) {
        for other in PanelMath.closes(when: panel, open: open) { close(other, .otherPanel) }
    }

    func didOpen(_ panel: MantelPanel) {
        open.insert(panel)
        onChange()
    }

    func didClose(_ panel: MantelPanel, _ reason: PanelCloseReason) {
        guard open.remove(panel) != nil else { return }
        onClosed(panel, reason)
        onChange()
    }

    func close(_ panel: MantelPanel, _ reason: PanelCloseReason) {
        switch panel {
        case .secondBar: secondBar.close(reason)
        case .group: group.close(reason)
        case .commandBar: closeCommandBar(reason)
        }
    }

    func closeAll(_ reason: PanelCloseReason) {
        for panel in open { close(panel, reason) }
    }

    /// The state the session published changed: what a panel lists follows it.
    func stateChanged() {
        secondBar.refresh()
        group.refresh()
    }

    /// The settings of how the panels look changed.
    func styleChanged() {
        secondBar.refresh()
        group.refresh()
    }
}

extension PanelEnvironment {
    /// The bars as the last read had them, the displays and the entry lists the panels are made from.
    @MainActor
    func entries(_ build: (MenuBarState, _ running: Set<String>, _ turnedOff: Set<String>, _ names: [String: String]) -> [SecondBarEntry]) -> [SecondBarEntry]? {
        guard let state = model.state else { return nil }
        let apps = runningApps.all
        var names: [String: String] = [:]
        for app in apps {
            if let id = app.bundleID, let name = app.name, names[id] == nil { names[id] = name }
        }
        let off: Set<String> = if case .apps(let ids) = state.lists.turnedOff { Set(ids) } else { [] }
        return build(state, Set(apps.compactMap(\.bundleID)), off, names)
    }

    /// The display a panel opens on: the one named, else the one with the pointer, else the main one.
    @MainActor
    func display(named uuid: String?) -> DisplayInfo? {
        let displays = layout()
        if let uuid, let known = displays.display(uuid: uuid) { return known }
        return displays.display(containing: NSEvent.mouseLocation) ?? displays.main
    }

    /// The panel's cells and frame for these entries on a display: laid out for the screen's width less the margins, and put under the
    /// bar at the anchor (CoreGraphics global points). The anchor is found again in the newest read every time, so a panel follows the
    /// item it is under when the bar moves it.
    @MainActor
    func placement(of entries: [SecondBarEntry], anchor kept: PanelAnchorSpec, on display: DisplayInfo) -> (cells: SecondBarLayout, frame: CGRect) {
        let displays = layout()
        let anchor = model.state.map {
            PanelAnchors.resolve(kept, display: display.uuid, inventory: $0.inventory, displaysChangedAt: displaysChangedAt())
        } ?? .rightAligned
        let screen = displays.cgRect(fromAppKit: display.frame)
        let cells = SecondBarGeometry.layout(entries: entries, maxWidth: screen.width - 2 * SecondBarGeometry.screenMargin)
        let bar = model.state?.inventory.bars.first { $0.displayUUID == display.uuid }
            ?? MenuBarGeometry(displayUUID: display.uuid, rect: CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: NSStatusBar.system.thickness),
                               notch: display.notch.map { displays.cgRect(fromAppKit: $0) })
        return (cells, SecondBarGeometry.frame(size: cells.size, anchor: anchor, bar: bar, screen: screen))
    }

    /// Where Mantel's own items are: their buttons, and the slots the last read found them in.
    @MainActor
    func ownItemFrames() -> [CGRect] {
        ownButtonFrames() + (model.state.map { PanelAnchors.ownItemFrames(in: $0.inventory) } ?? [])
    }
}

/// What the panels read of the person's settings: kept by `MenuBarController`, which is told when they change.
@MainActor
final class PanelSettings {
    var secondBar: SecondBarSettings
    var allowClockAndControlCenter: Bool
    /// When the displays last changed, nil before they have.
    var displaysChangedAt: Date?

    init(secondBar: SecondBarSettings, allowClockAndControlCenter: Bool) {
        self.secondBar = secondBar
        self.allowClockAndControlCenter = allowClockAndControlCenter
    }
}
