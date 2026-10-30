import MKCore

/// Turns what the person and the system ask for into one `VisibilityPlan`.
///
/// Every layer starts from the one below it and overrides what it has an opinion about. From the lowest to the highest:
///
/// 1. **Sections.** An app is where it was put, or in the new-items section if it was never put anywhere. Shown is visible;
///    Hidden and Always Hidden are concealed.
/// 2. **Rules.** The apps a rule shows are visible.
/// 3. **A wide screen.** On one, with the switch on, everything is visible.
/// 4. **A reveal.** `.hidden` makes Hidden visible; `.all` makes Hidden and Always Hidden visible. While one lasts, the apps a swap
///    conceals to make room are concealed again.
/// 5. **Focus Mode.** Only Mantel, the clock and Control Center are visible.
/// 6. **Icons asked for** (`iconReveals`). The apps of those icons, and the system items among them, are visible, whatever Focus Mode
///    says; and while there are any, the Shown apps that were concealed to make room for them (`iconRoomConcealed`) are concealed.
///
/// The reason the plan gives (`PlanSource`) is the highest of focus mode, a reveal, an icon asked for, a wide screen, rules and
/// the sections, in that order: an icon asked for doesn't take the reason from a reveal.
///
/// System items follow the same layers (rules name apps, so they don't reach them), with two differences: the clock and Control
/// Center count as Shown unless hiding them is allowed, and Focus Mode keeps them whatever the permission.
public enum PlanBuilder {
    public static func build(_ inputs: PlanInputs) -> VisibilityPlan {
        let sections = inputs.sections
        let wide = inputs.wideScreen.applies
        let revealed: Set<MenuBarSection> = switch inputs.reveal {
        case .off: []
        case .hidden: [.hidden]
        case .all: [.hidden, .alwaysHidden]
        }
        let revealing = inputs.reveal != .off

        var shownByRule: Set<String> = []
        var ruleIsActive = false
        for case .show(let bundleIDs) in inputs.rules where !bundleIDs.isEmpty {
            shownByRule.formUnion(bundleIDs)
            ruleIsActive = true
        }

        // Apps. Mantel's own icons are always visible.
        let iconApps = Set(inputs.iconReveals.filter { !$0.isSystem }.map(\.bundleID))
        let iconModules = Set(inputs.iconReveals.compactMap { item -> String? in
            if case .system(let module) = item.key { module } else { nil }
        })
        let iconRevealing = !inputs.iconReveals.isEmpty

        var visible: Set<String> = [inputs.ownBundleID]
        var concealed: Set<String> = []
        for bundleID in inputs.runningBundleIDs where bundleID != inputs.ownBundleID {
            let section = sections.section(ofApp: bundleID)
            var isVisible = section == .shown
            if shownByRule.contains(bundleID) { isVisible = true }
            if wide { isVisible = true }
            if revealed.contains(section) { isVisible = true }
            if revealing && inputs.swapConcealed.contains(bundleID) { isVisible = false }
            if inputs.focusMode { isVisible = false }
            if iconRevealing && inputs.iconRoomConcealed.contains(bundleID) { isVisible = false }
            if iconApps.contains(bundleID) { isVisible = true }
            if isVisible { visible.insert(bundleID) } else { concealed.insert(bundleID) }
        }

        // System items: the numbers of the concealed ones come off the list of every number.
        var concealedNumbers: Set<Int> = []
        for (module, number) in SystemItemTable.numbers {
            let staysOnBar = SystemItemTable.unmovable.contains(module)
            var section = sections.systemItems[module] ?? .shown
            if staysOnBar && !inputs.allowHidingClockAndControlCenter { section = .shown }
            var isVisible = section == .shown
            if wide { isVisible = true }
            if revealed.contains(section) { isVisible = true }
            if inputs.focusMode { isVisible = staysOnBar }
            if iconModules.contains(module) { isVisible = true }
            if !isVisible { concealedNumbers.insert(number) }
        }

        let concealedSections: Set<MenuBarSection> = if inputs.focusMode {
            Set(MenuBarSection.allCases)
        } else if wide {
            []
        } else {
            Set<MenuBarSection>([.hidden, .alwaysHidden]).subtracting(revealed)
        }

        let source: PlanSource = if inputs.focusMode {
            .focusMode
        } else if revealing {
            .reveal(inputs.reveal)
        } else if iconRevealing {
            .iconReveal
        } else if wide {
            .wideScreen
        } else if ruleIsActive {
            .rules
        } else {
            .sections
        }

        return VisibilityPlan(visibleBundleIDs: visible, concealedBundleIDs: concealed,
                              visibleSystemItems: Set(VisibilityPlan.allSystemItems).subtracting(concealedNumbers),
                              concealedSections: concealedSections, source: source)
    }
}
