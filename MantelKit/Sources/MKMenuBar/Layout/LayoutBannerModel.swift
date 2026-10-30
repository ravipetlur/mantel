import Foundation
import MKLayout

extension LayoutWriterAvailability {
    /// Whether a reorder can be asked for: the file is given and reordering works here. A write that has to wait (`held`) is kept and made
    /// when it can be, so the person can go on.
    public var allowsReordering: Bool {
        switch self {
        case .available, .held: true
        case .needsGrant, .broken: false
        }
    }
}

/// One line of the Layout pane's banner.
public struct LayoutBannerLine: Sendable, Equatable, Identifiable {
    public let text: String
    /// The line comes with a button that has the person choose the layout file.
    public let offersGrant: Bool
    /// A row that says nothing and is as tall as a refusal's: it holds the place a refusal's row would take (`lines(…dragging:)`).
    public let isPlaceholder: Bool

    public var id: String { text }

    public init(text: String, offersGrant: Bool = false, isPlaceholder: Bool = false) {
        self.text = text
        self.offersGrant = offersGrant
        self.isPlaceholder = isPlaceholder
    }

    /// The row that holds a refusal's place while something is being dragged.
    public static let placeholder = LayoutBannerLine(text: "", isPlaceholder: true)
}

/// What the Layout pane's banner says: why reordering isn't available or needs saying, one line each, in this order.
///
/// 1. The writer: it needs the file (with the button), is held (its reason), or is broken (its reason).
/// 2. The last write wasn't accepted.
/// 3. Mantel's own icons were left unplaced among icons that can't be reordered.
/// 4. A palette item was dropped without the file, and was put at the end of its section (not once the writer is available).
/// 5. A drop that was refused, when none of the lines above says it already.
///
/// **While something is being dragged** the refusal's row is always there (`dragging`), with the refusal's words when there are some
/// to add, or empty, so that the rows below never move under the pointer when a refusal comes and goes.
public enum LayoutBannerModel {
    public static func lines(status: LayoutStatus?, addedAtTheEndOf section: MenuBarSection?, refusal: String?,
                             dragging: Bool = false) -> [LayoutBannerLine] {
        var lines: [LayoutBannerLine] = []
        if let status {
            switch status.availability {
            case .available: break
            case .needsGrant: lines.append(LayoutBannerLine(text: LayoutCopy.needsGrantBanner, offersGrant: true))
            case .held(let reason), .broken(let reason): lines.append(LayoutBannerLine(text: reason))
            }
            if case .notAccepted = status.lastError { lines.append(LayoutBannerLine(text: LayoutCopy.notAcceptedBanner)) }
            // `notPlaced` also names the apps that had no gap; the line is about Mantel's own icons.
            if status.lastReport?.notPlaced.contains(where: { OwnItems.kind(name: $0, description: nil) != nil }) == true {
                lines.append(LayoutBannerLine(text: LayoutCopy.notPlacedBanner))
            }
        }
        if let section, status?.availability != .available {
            lines.append(LayoutBannerLine(text: LayoutCopy.addedAtTheEnd(of: section)))
        }
        if let refusal, !lines.contains(where: { $0.text == refusal }) {
            lines.append(LayoutBannerLine(text: refusal))
        } else if dragging {
            lines.append(.placeholder)
        }
        return lines
    }

    /// The words to flash for a refused drop. Without the file the refusal is the banner's own line about it. When the file is given
    /// and reordering is broken, that line is wrong: the standing line is the writer's reason, so that is what is flashed (it is on show
    /// already, so the banner only highlights it and gains no row).
    public static func flashed(_ refusal: String, status: LayoutStatus?) -> String {
        if refusal == LayoutCopy.needsGrantBanner, case .broken(let reason)? = status?.availability { return reason }
        return refusal
    }

    /// What a restore that didn't happen says. A restore asked for while writes are held is answered with the generic failure, and the
    /// reason for the hold is what the person needs: it is read from the error (the status the pane drew may not have caught up with the
    /// hold), and from the status when the error doesn't say. A restore without the file says what the banner says, not the writer's
    /// words about Settings › Layout, which this is.
    public static func restoreFailure(_ error: LayoutWriteError, status: LayoutStatus?) -> String {
        if case .failed(let text) = error, LayoutHold.reasons.contains(text) { return text }
        if case .needsGrant = error { return LayoutCopy.needsGrantBanner }
        if case .held(let reason)? = status?.availability { return reason }
        return error.errorDescription ?? LayoutWords.couldntChange
    }
}
