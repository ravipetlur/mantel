import CoreGraphics
import Foundation
import MKCore
import MKLayout

/// What the spacer engine asks of the app's status items. The app's implementation keeps the items only while the engine is in use:
/// an empty `divider` (see `SpacerWidths.removed`) is its cue to take them all off the bar.
@MainActor
public protocol SpacerControlling: AnyObject, Sendable {
    func show(widths: SpacerWidths)
}

/// Hides icons with wide invisible status items of Mantel's own: the items to the left of one are pushed off the bar. It works by
/// where the items sit, and not by which app they are, so it is the way of last resort (`EngineStatus.degraded`).
///
/// The bars the widths are made for come from `setBars`; until it is called, every spacer is collapsed.
public actor SpacerEngine: HidingEngine {
    private let spacers: any SpacerControlling
    private var bars: [MenuBarGeometry] = []
    private var plan: VisibilityPlan?
    private let turnstile = Turnstile()

    public init(spacers: any SpacerControlling) {
        self.spacers = spacers
    }

    public nonisolated var kind: HidingEngineKind {
        .spacer
    }

    public func availability() async -> EngineAvailability {
        .available
    }

    public func apply(_ plan: VisibilityPlan) async throws {
        await turnstile.enter()
        defer { turnstile.leave() }
        self.plan = plan
        await show(SpacerLayout.widths(for: plan, bars: bars))
    }

    /// The menu bars as the last inventory has them. When a plan is in force, the spacers are made again for them.
    public func setBars(_ bars: [MenuBarGeometry]) async {
        await turnstile.enter()
        defer { turnstile.leave() }
        guard bars != self.bars else { return }
        self.bars = bars
        if let plan { await show(SpacerLayout.widths(for: plan, bars: bars)) }
    }

    public func tearDown() async {
        await turnstile.enter()
        defer { turnstile.leave() }
        plan = nil
        await show(.removed)
    }

    private func show(_ widths: SpacerWidths) async {
        await spacers.show(widths: widths)
    }
}
