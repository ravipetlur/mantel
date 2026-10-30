import AppKit
import MKCore
import MKLayout
import MKMenuBar
import Synchronization

/// What the app clicks an icon with: the one `IconClickDriver` of the app, made with what it needs from the system (the pointer, the
/// poster and the rehide delay; the process that owns an app's icons is the session's to say), and the toast that says why a click didn't happen. The second bar's and a group
/// panel's cells go through it, and so will the command bar, the hotkeys and the commands.
///
/// - **Clicks go only through the driver** and its rules (`ClickRouteRules.measured`): nothing here posts an event or presses an item.
/// - **A click is in flight** from the moment it is asked for until the driver answers (`isClickInFlight`): the app the click brings to
///   the front is not the person leaving the panel (`PanelMath.closesOnAppSwitch`).
/// - **Failures are told as `ClickNotice` says:** a toast naming the icon's app, or an alert when Mantel's own grant is missing.
@MainActor
final class IconClickService {
    /// What is read from outside the main actor: the rehide delay the person chose, where the bars are and which of them are shown.
    private struct Shared: Sendable {
        var rehide: RehideDelay
        var bars: [MenuBarGeometry] = []
        var shown = ShownBarsCache()
    }

    /// The driver's closures hold this and not the service, which belongs to the main actor.
    private final class Box: Sendable {
        let state: Mutex<Shared>

        init(_ shared: Shared) {
            state = Mutex(shared)
        }
    }

    private let session: MenuBarSession
    private let driver: IconClickDriver
    private let shared: Box
    private var inFlight = 0

    /// - Parameters:
    ///   - scanner: what finds and presses the icons (the coordinator's, so what its scans learned is what a click goes by).
    ///   - layout: the displays as they are now, for the pointer.
    init(session: MenuBarSession, scanner: MenuBarScanner, layout: @escaping @Sendable () -> DisplayLayout, rehide: RehideDelay) {
        let shared = Box(Shared(rehide: rehide))
        self.session = session
        self.shared = shared
        let windows = LiveWindowList()
        driver = IconClickDriver(
            session: session, locator: scanner, presser: scanner, poster: LiveClickPoster(), windows: windows,
            pointerInBar: {
                // The pointer is in a bar that is on screen: a bar a full-screen app hides doesn't hold an icon.
                let spot = layout().cgPoint(fromAppKit: NSEvent.mouseLocation)
                return shared.state.withLock { shared in
                    let shown = shared.shown.shownBars(at: spot, bars: shared.bars, now: Date(), windows: { windows.onScreenWindows() })
                    return shared.bars.contains { shown.contains($0.displayUUID) && $0.rect.contains(spot) }
                }
            },
            clock: SystemClock(), rules: .measured, rehide: { shared.state.withLock { $0.rehide } },
            captured: { location in await session.captureClickedIcon(location) })
    }

    var isClickInFlight: Bool { inFlight > 0 }

    func setRehide(_ rehide: RehideDelay) {
        shared.state.withLock { $0.rehide = rehide }
    }

    /// The bars as the last read had them: the pointer in one of them that is on screen holds an icon on the bar.
    func setBars(_ bars: [MenuBarGeometry]) {
        shared.state.withLock { $0.bars = bars }
    }

    /// Clicks the icon, and says why when it couldn't be (`ClickNotice`). `beforeClick` runs once the icon is on the bar and before the click is sent
    /// (a panel closes there).
    ///
    /// - Parameters:
    ///   - title: the icon's app (or the system item's name), for the toast.
    ///   - display: the display whose bar the icon is looked for on: the panel's.
    ///   - toasts: whether a failure is told here (a toast, or the alert for Mantel's own missing grant). A command says it in its own answer.
    @discardableResult
    func click(_ item: ItemID, kind: ClickKind, title: String, display: String?, origin: ClickOrigin, toasts: Bool = true,
               beforeClick: @escaping @Sendable () async -> Void = {}) async -> IconClickOutcome {
        inFlight += 1
        defer { inFlight -= 1 }
        let outcome = await driver.click(IconClickRequest(item: item, kind: kind, display: display, origin: origin), beforeClick: beforeClick)
        tell(ClickNotice.of(outcome, app: title, mantelIsTrusted: { AccessibilityTrust.isTrusted }, announces: toasts))
        return outcome
    }

    /// Shows the icon for the rehide delay, without clicking it. An icon that can't be shown is told as a click's failure is, and returned:
    /// the questions are the click path's own (`IconShowCheck`), asked before anything is revealed.
    ///
    /// - Parameters:
    ///   - title: the icon's app (or the system item's name), for the toast.
    ///   - toasts: whether a refusal is told here. A command says it in its own answer.
    @discardableResult
    func show(_ item: ItemID, title: String, toasts: Bool = true) async -> IconClickFailure? {
        let pid = item.isSystem ? nil : await session.extrasOwnerPID(ofApp: item.bundleID)
        let unattached = item.isSystem ? false : await session.isUnattached(item.bundleID)
        let turnedOff = item.isSystem ? false : await session.isTurnedOff(item.bundleID)
        let noSuchIcon = item.isSystem ? false : await session.hasNoSuchIcon(item)
        let refusal = IconShowCheck.refusal(for: item, hasProcess: pid != nil, hasItems: await session.hasItems(ofApp: item.bundleID),
                                            planConceals: await session.planConceals(item), neverDrawn: unattached || turnedOff,
                                            noSuchIcon: noSuchIcon)
        if let refusal {
            if noSuchIcon { Log.info("click", "\(item.bundleID) has no such icon now") }
            tell(ClickNotice.ofShow(refusal, app: title, announces: toasts))
            return refusal
        }
        await driver.show(item)
        return nil
    }

    private func tell(_ notice: ClickNotice) {
        switch notice {
        case .toast(let toast): HUDToast.show(symbol: toast.symbol, text: toast.text)
        case .alert(let content): GrantAlert.show(content)
        case .nothing: break
        }
    }
}
