import CoreGraphics
import Foundation
import MKCore

/// What the probes read with `MenuBarReader` (every window MenuBarAgent has, every app's items) is put through the same choosing and
/// matching the scanner uses, so that a probe and the product see one menu bar.
extension MenuBarSnapshot {
    /// The window of each display the scanner would use: of those whose slots were all read, the one with the most names of its own.
    func chosenWindows() -> [ChosenWindow] {
        let reads = agentWindows.enumerated().map { index, window in
            AgentWindowRead(index: index, frame: window.frame, slotFrames: window.slots.map(\.frame),
                            uniqueNameCount: AgentWindowReader.identifierCount(window.slots))
        }
        return AgentWindowChooser.choose(reads, layout: layout)
    }

    /// The bar of each display: the chosen window's frame and slots.
    func bars() -> [MenuBarGeometry] {
        let reads = chosenWindows()
        return reads.map { window in
            let notch = layout.display(uuid: window.displayUUID)?.notch.map(layout.cgRect(fromAppKit:))
            return MenuBarGeometry(displayUUID: window.displayUUID, rect: window.frame, notch: notch)
        }
    }

    /// The matcher's input: for each display the window with the most identifiers (the first of those that have as many), and the apps
    /// that answered.
    func matchInput(ownBundleID: String) -> MatchInput {
        let bars = chosenWindows().map { window in
            var best = window.index
            for index in window.candidates
            where AgentWindowReader.identifierCount(agentWindows[index].slots) > AgentWindowReader.identifierCount(agentWindows[best].slots) {
                best = index
            }
            return MatchBar(displayUUID: window.displayUUID, rect: agentWindows[best].frame, slots: agentWindows[best].slots)
        }
        return MatchInput(capturedAt: capturedAt, layout: layout, bars: bars, apps: apps.filter { !$0.timedOut },
                          ownBundleID: ownBundleID)
    }
}
