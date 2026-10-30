import AppKit
import MKUpdate
import SwiftUI

/// The update window's content: who is offered, the release notes, what is happening and the choices. One size in every
/// state, and each button keeps its place and width, whatever the state: Skip This Version on the left, the other two on
/// the right (Later or Cancel or Close, then Install and Relaunch, Try Again or Show Disk Image).
struct UpdateView: View {
    let center: UpdateCenter

    private enum Layout {
        static let skipWidth: CGFloat = 130
        static let secondaryWidth: CGFloat = 70
        static let primaryWidth: CGFloat = 150
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let release = center.offer {
                header(release)
                notes(release)
                status
                buttons
            } else {
                // The window closes as the offer goes; this is what shows in the moment between.
                Text("No update is on offer.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(width: UpdateWindowController.contentSize.width, height: UpdateWindowController.contentSize.height)
    }

    // MARK: Header

    private func header(_ release: ReleaseInfo) -> some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Mantel \(release.version.description) is available").font(.title3.bold())
                Text("You have \(center.currentVersion.description)").foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Notes

    private func notes(_ release: ReleaseInfo) -> some View {
        let blocks = center.notesBlocks(for: release)
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if blocks.isEmpty {
                    Text("This release has no notes.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        NotesBlockView(block: block)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Release notes for Mantel \(release.version.description)")
    }

    // MARK: Status

    /// What is happening, below the notes: nothing while the release is only offered.
    @ViewBuilder
    private var status: some View {
        switch center.flow.state {
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloading\u{2026}").font(.subheadline)
                ProgressView(value: progress)
                    .accessibilityLabel("Download progress")
            }
        case .verifying(let step):
            VStack(alignment: .leading, spacing: 4) {
                Text("Verifying\u{2026}").font(.subheadline)
                ProgressView().progressViewStyle(.linear)
                    .accessibilityLabel("Verifying the download")
                Text(step.caption).font(.caption).foregroundStyle(.secondary)
            }
        case .installing:
            if center.restartIsWaiting {
                // The new app is in place; the relaunch waits for an open dialog to be closed.
                Text(InstallFlow.restartWaitingText).font(.subheadline)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Installing\u{2026}").font(.subheadline)
                    ProgressView().progressViewStyle(.linear)
                        .accessibilityLabel("Installing")
                }
            }
        case .handedOff:
            // Every check passed, but Mantel can't change the folder it is in: the person finishes by hand.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.down.app.fill").foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drag Mantel to Applications to finish").font(.subheadline.bold())
                    Text("The new version is checked and open in Finder. Mantel can't replace itself where it is. Quit Mantel first, so Finder can replace it, then drag the new copy onto Applications and open it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        case .failed(let failure):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(failure.message).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        default:
            EmptyView()
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        let state = center.flow.state
        return HStack(spacing: 12) {
            if case .available = state {
                slot("Skip This Version", width: Layout.skipWidth) { center.skipThisVersion() }
            } else {
                Color.clear.frame(width: Layout.skipWidth, height: 1)
            }
            Spacer()
            secondary(state)
            primary(state)
        }
    }

    /// Later, Cancel while the download or verifying can be cancelled (it stays, off, once installing starts), or Close
    /// after a failure or a hand-off.
    @ViewBuilder
    private func secondary(_ state: InstallFlow.State) -> some View {
        switch state {
        case .downloading, .verifying, .installing:
            slot("Cancel", width: Layout.secondaryWidth) { center.cancelInstall() }
                .disabled(!center.flow.canCancel)
                .keyboardShortcut(.cancelAction)
        case .failed, .handedOff:
            slot("Close", width: Layout.secondaryWidth) { center.later() }
                .keyboardShortcut(.cancelAction)
        default:
            slot("Later", width: Layout.secondaryWidth) { center.later() }
                .keyboardShortcut(.cancelAction)
        }
    }

    /// Install and Relaunch (the default), Try Again after a failure (not after one that came with the new version
    /// installed, or with the app missing), Show Disk Image after a hand-off, and nothing while an install runs.
    @ViewBuilder
    private func primary(_ state: InstallFlow.State) -> some View {
        switch state {
        case .failed(let failure) where !failure.canTryAgain:
            Color.clear.frame(width: Layout.primaryWidth, height: 1)
        case .failed:
            slot("Try Again", width: Layout.primaryWidth) { center.tryAgain() }
                .keyboardShortcut(returnKey)
        case .handedOff:
            slot("Show Disk Image", width: Layout.primaryWidth) { center.showDiskImage() }
                .keyboardShortcut(returnKey)
                .disabled(center.handedOffVolume == nil)
        case .downloading, .verifying, .installing:
            Color.clear.frame(width: Layout.primaryWidth, height: 1)
        default:
            slot("Install and Relaunch", width: Layout.primaryWidth) { center.installAndRelaunch() }
                .keyboardShortcut(returnKey)
                .disabled(!center.canInstall)
        }
    }

    /// Return for the main button, but only once the window has been key for a moment (`DefaultActionArming`): an offer
    /// can open while the person is typing elsewhere, and a Return meant for that must not install. Until then the
    /// button works by click.
    private var returnKey: KeyboardShortcut? {
        center.defaultActionArmed ? .defaultAction : nil
    }

    /// A button of a fixed width: the label fills the width, which the bezel then takes, so a button is as wide in every
    /// state, and its neighbours don't move.
    private func slot(_ title: String, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .frame(width: width)
    }
}

/// One block of the notes, laid out as `ReleaseNotes` cut it: `Text` draws a block's inline styles and links, and this
/// gives each kind of block its own look.
private struct NotesBlockView: View {
    let block: ReleaseNotes.Block

    /// A list nested deeper than this is indented no further, which keeps the indent on the spacing scale (16 or 32).
    private static let deepestIndent = 2

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(text).fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).monospacedDigit().frame(minWidth: 16, alignment: .trailing)
                    .accessibilityHidden(true)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(min(depth, Self.deepestIndent)) * 16)
        case .quote(let text):
            HStack(spacing: 8) {
                Capsule().fill(.tertiary).frame(width: 3)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .codeBlock(let code):
            Text(code)
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .rule:
            Divider()
        }
    }
}

private extension VerifyStep {
    /// What the step checks, in a few words, for the line under "Verifying…".
    var caption: String {
        switch self {
        case .checksum: "Checking the download against its checksum"
        case .gatekeeperImage: "Checking the disk image with macOS"
        case .mount: "Opening the disk image"
        case .appIdentity: "Checking which app and version it holds"
        case .appSignature: "Checking the app's signature"
        case .gatekeeperApp: "Checking the app with macOS"
        }
    }
}
