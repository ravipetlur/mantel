import AppKit
import MKCore
import SwiftUI

/// One step at a time, in one layout: a symbol, the title and one or two sentences at the top, and in the bar at the bottom
/// the step's one primary button. What each step says is `OnboardingCopy`'s.
///
/// Nothing a step shows changes the window's size or moves the button. The view is `size` whatever it holds, and the primary
/// button is as wide as the widest label of any step, so it is the same width on every step.
struct OnboardingView: View {
    /// The window's content size, the same on every step.
    static let size = CGSize(width: 520, height: 420)

    /// The symbol's height, so that the title under it sits at the same place on every step: the symbols are not all
    /// as tall as each other.
    private static let symbolHeight: CGFloat = 32

    let model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: Self.symbol(for: model.step))
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .frame(height: Self.symbolHeight)
                Text(OnboardingCopy.title(for: model.step)).font(.title.bold())
                // The whole text, however many lines it takes, never cut short for what is under it.
                Text(OnboardingCopy.text(for: model.step, inputs: model.inputs))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)

            Divider()
            // The bar: the primary button, at the bottom right on every step, and the same size.
            HStack {
                Spacer()
                Button(action: primaryAction) {
                    // Every label any step gives the button, unseen, with this step's on top: the button is as wide as
                    // the widest of them, whatever the step. (A button that changed width with its label would leave its
                    // keyboard-focus ring behind at the old width.)
                    ZStack {
                        ForEach(OnboardingCopy.buttonTitles, id: \.self) { title in
                            Text(title).hidden().accessibilityHidden(true)
                        }
                        Text(OnboardingCopy.buttonTitle(for: model.step, inputs: model.inputs))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isPrimaryDisabled)
            }
            .padding(20)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .task {
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var isPrimaryDisabled: Bool {
        switch model.step {
        case .location: model.isMoving
        case .welcome, .accessibility, .dots, .done: false
        }
    }

    private func primaryAction() {
        switch model.step {
        case .welcome, .dots:
            model.advance()
        case .accessibility:
            AccessibilityTrust.promptAndOpenSettings()
        case .location:
            if model.inputs.install == .translocated {
                // It can't be moved, so the person drags it in by hand, and this copy has to be gone first.
                NSApp.terminate(nil)
            } else {
                Task { await model.moveToApplications() }
            }
        case .done:
            model.done()
        }
    }

    private static func symbol(for step: OnboardingStep) -> String {
        switch step {
        case .welcome: "hand.wave"
        case .accessibility: "accessibility"
        case .location: "folder"
        case .dots: "ellipsis.circle"
        case .done: "checkmark.seal.fill"
        }
    }
}
