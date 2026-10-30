import MKCore
import Testing

@testable import MKLayout

@Suite("Own items' visibility", .timeLimit(.minutes(1)))
struct OwnItemsVisibilityTests {
    private let hiddenSpacer = LayoutSpacer(id: SpacerID(rawValue: "00000001"), width: 12)
    private let shownSpacer = LayoutSpacer(id: SpacerID(rawValue: "00000002"), width: 12)
    private let hiddenGroup = IconGroup(id: GroupID(rawValue: "0000000a"), title: "Work")
    private let alwaysGroup = IconGroup(id: GroupID(rawValue: "0000000b"), title: "Play")

    /// A spacer in Shown and one in Hidden, a group in Hidden and one in Always Hidden.
    private var sections: SectionModel {
        var sections = SectionModel()
        sections.addSpacer(shownSpacer, in: .shown, at: 0)
        sections.addSpacer(hiddenSpacer, in: .hidden, at: 0)
        sections.addGroup(hiddenGroup, in: .hidden, at: 1)
        sections.addGroup(alwaysGroup, in: .alwaysHidden, at: 0)
        return sections
    }

    private func plan(concealing concealed: Set<MenuBarSection>, source: PlanSource = .sections) -> VisibilityPlan {
        VisibilityPlan(visibleBundleIDs: [], concealedBundleIDs: [], visibleSystemItems: [], concealedSections: concealed, source: source)
    }

    private func shown(_ plan: VisibilityPlan, dots: DotSettings = DotSettings(), alwaysHiddenHasApps: Bool = false,
                       sections: SectionModel? = nil) -> OwnItemsShown {
        OwnItemsVisibility.shown(sections: sections ?? self.sections, plan: plan, dots: dots, alwaysHiddenHasApps: alwaysHiddenHasApps)
    }

    @Test func hiddenSectionSpacerHiddenWhenCollapsed() {
        let collapsed = shown(plan(concealing: [.hidden, .alwaysHidden]))
        #expect(collapsed.spacers == [shownSpacer.id])
        #expect(collapsed.groups == [])
    }

    @Test func revealShowsHiddenSectionItems() {
        let hidden = shown(plan(concealing: [.alwaysHidden], source: .reveal(.hidden)))
        #expect(hidden.spacers == [shownSpacer.id, hiddenSpacer.id])
        #expect(hidden.groups == [hiddenGroup.id])
        let all = shown(plan(concealing: [], source: .reveal(.all)))
        #expect(all.spacers == [shownSpacer.id, hiddenSpacer.id])
        #expect(all.groups == [hiddenGroup.id, alwaysGroup.id])
    }

    @Test func focusModeShowsOnlyDots() {
        var dots = DotSettings()
        dots.showsDivider = true
        let focus = shown(plan(concealing: [.shown, .hidden, .alwaysHidden], source: .focusMode), dots: dots, alwaysHiddenHasApps: true)
        #expect(focus == OwnItemsShown(hiddenDot: true, alwaysDot: true, divider: false, spacers: [], groups: []))
        // Even a plan that conceals nothing shows only the dots in Focus Mode.
        let odd = shown(plan(concealing: [], source: .focusMode), dots: dots)
        #expect(odd.spacers.isEmpty && odd.groups.isEmpty && !odd.divider)
    }

    @Test func alwaysDotWhenNeededOrAlways() {
        let collapsed = plan(concealing: [.hidden, .alwaysHidden])
        #expect(shown(collapsed).alwaysDot == false, "nothing in Always Hidden")
        #expect(shown(collapsed, alwaysHiddenHasApps: true).alwaysDot, "an app is running in Always Hidden")
        var always = DotSettings()
        always.alwaysDot = .always
        #expect(shown(collapsed, dots: always).alwaysDot, "set to always, with Always Hidden empty")
        #expect(shown(collapsed, dots: always).hiddenDot)
    }

    @Test func groupedAppsCountForAlwaysDot() {
        // A grouped app is in Always Hidden, so the session's answer to "does Always Hidden hold a running app" counts it, and •• shows.
        var grouped = SectionModel()
        grouped.addGroup(hiddenGroup, in: .hidden, at: 0)
        grouped.move(app: "com.example.grouped", toGroup: hiddenGroup.id, at: 0)
        #expect(grouped.apps["com.example.grouped"]?.section == .alwaysHidden)
        #expect(grouped.apps["com.example.grouped"]?.group == hiddenGroup.id)
        let collapsed = plan(concealing: [.hidden, .alwaysHidden])
        #expect(shown(collapsed, alwaysHiddenHasApps: true, sections: grouped).alwaysDot)
    }

    @Test func hideBothDots() {
        var dots = DotSettings()
        dots.hideBothDots = true
        dots.alwaysDot = .always
        let result = shown(plan(concealing: []), dots: dots, alwaysHiddenHasApps: true)
        #expect(!result.hiddenDot && !result.alwaysDot)
        // The other own items don't follow the dots.
        #expect(result.spacers == [shownSpacer.id, hiddenSpacer.id])
    }

    @Test func divider() {
        let collapsed = plan(concealing: [.hidden, .alwaysHidden])
        #expect(shown(collapsed).divider == false)
        var dots = DotSettings()
        dots.showsDivider = true
        #expect(shown(collapsed, dots: dots).divider)
    }

    @Test func anItemNoSectionHoldsIsNotDrawn() {
        var loose = SectionModel()
        loose.spacers[shownSpacer.id] = shownSpacer
        #expect(shown(plan(concealing: []), sections: loose).spacers.isEmpty)
    }

    @Test func beforeTheFirstReadOnlyTheDotsAreThere() {
        #expect(OwnItemsVisibility.beforeTheFirstRead(dots: DotSettings()) == OwnItemsShown(hiddenDot: true))
        var dots = DotSettings()
        dots.alwaysDot = .always
        dots.showsDivider = true
        #expect(OwnItemsVisibility.beforeTheFirstRead(dots: dots) == OwnItemsShown(hiddenDot: true, alwaysDot: true))
        dots.hideBothDots = true
        #expect(OwnItemsVisibility.beforeTheFirstRead(dots: dots) == OwnItemsShown())
    }

    @Test func creationOrderFollowsTheSectionsThenTheGroups() {
        // Shown: the spacer; Hidden: the group, then the spacer; Always Hidden: the other group.
        #expect(OwnItemsVisibility.creationOrder(sections) == [.spacer(shownSpacer.id), .spacer(hiddenSpacer.id), .group(hiddenGroup.id),
                                                               .group(alwaysGroup.id)])
        // A group no list holds comes after the lists' items, in `groupOrder`; a spacer no list holds comes last.
        var loose = sections
        let straggler = IconGroup(id: GroupID(rawValue: "0000000c"), title: "Stray")
        loose.groups[straggler.id] = straggler
        loose.groupOrder.append(straggler.id)
        let lost = LayoutSpacer(id: SpacerID(rawValue: "00000009"), width: 8)
        loose.spacers[lost.id] = lost
        #expect(OwnItemsVisibility.creationOrder(loose).suffix(2) == [.group(straggler.id), .spacer(lost.id)])
        #expect(OwnItemsVisibility.creationOrder(SectionModel()).isEmpty)
    }

    @Test func anIdTheLayoutCantNameHasNoStatusItem() {
        // A layout file may hold a spacer whose id is the one the wide spacer's divider goes by: it would take that item's place.
        var odd = sections
        for raw in ["divider", "divider.2", "always", ""] {
            let spacer = LayoutSpacer(id: SpacerID(rawValue: raw), width: 8)
            odd.spacers[spacer.id] = spacer
            let group = IconGroup(id: GroupID(rawValue: raw), title: nil)
            odd.groups[group.id] = group
            odd.groupOrder.append(group.id)
        }
        #expect(OwnItemsVisibility.creationOrder(odd) == OwnItemsVisibility.creationOrder(sections))
    }
}
