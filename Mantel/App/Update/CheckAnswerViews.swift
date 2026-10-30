import MKUpdate
import SwiftUI

/// The symbol that goes with a check's words: a spinner while it runs, a checkmark, a warning sign, a download arrow. One
/// fixed 16 pt slot, so the words beside it start in the same place in every state.
struct CheckMarkView: View {
    let mark: CheckAnswer.Mark

    static let size: CGFloat = 16

    var body: some View {
        Group {
            switch mark {
            case .spinner:
                ProgressView().controlSize(.small)
            case .checkmark:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .available:
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
    }
}

/// What the popover under the dot shows: the answer of the check that was asked from the dots' menu. It keeps
/// the last answer that had something to show, so the words stay up while the popover fades out.
@Observable
final class CheckPopoverModel {
    var answer = CheckAnswer(.checking, source: .dotsMenu)
}

/// The popover's content: the mark and the title on one line, the plain reason of a failure under it, and OK. A fixed
/// width, so it never jumps sideways as the words change; "Checking…" and "up to date" have one line each and so the
/// same height, and only a failure, which has a reason and a button to hold, is taller.
struct CheckPopoverView: View {
    let model: CheckPopoverModel
    /// OK, and anything else that ends the popover.
    let close: () -> Void

    static let width: CGFloat = 280

    var body: some View {
        let answer = model.answer
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let mark = answer.mark { CheckMarkView(mark: mark) }
                Text(answer.title)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = answer.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if answer.hasOKButton {
                HStack {
                    Spacer()
                    Button("OK", action: close)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: Self.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }
}

/// The line under Check Now in Settings › About: the mark and the words of the answer. It always has the height of two
/// lines (a failure's reason can wrap) and one width, with the mark at its left edge, and says nothing, in the same space,
/// when there is no answer, so nothing in the pane shifts as a check starts and ends, and the mark never moves sideways.
struct CheckAnswerLine: View {
    let answer: CheckAnswer?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let mark = answer?.mark { CheckMarkView(mark: mark) } else { Color.clear.frame(width: CheckMarkView.size, height: CheckMarkView.size) }
            Text(answer?.title ?? " ")
                .font(.callout)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
