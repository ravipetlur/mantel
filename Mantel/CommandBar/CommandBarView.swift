import AppKit
import MKCore
import MKLayout
import MKSearch
import Observation
import SwiftUI

/// What the command bar shows: what was typed, the results, which one the keyboard is on and how the panel looks. The view draws it and
/// the controller changes it; what a key does is the package's (`CommandBarKeys`).
@MainActor
@Observable
final class CommandBarModel {
    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    private(set) var results: [SearchResult] = []
    /// The result the keyboard is on; nil while there are none.
    private(set) var selected: Int?
    /// The result the pointer is over.
    var hovered: Int?
    var style = PanelStyle()
    /// Counts up each time the bar opens, so that the field takes the keyboard again.
    private(set) var focusToken = 0
    /// The line of hints under the results.
    var footer = ""
    @ObservationIgnored var queryChanged: () -> Void = {}

    var selectedResult: SearchResult? {
        selected.flatMap { results[safe: $0] }
    }

    func set(results: [SearchResult]) {
        let kept = selectedResult?.id
        self.results = results
        hovered = nil
        selected = CommandBarSelection.selecting(results: results, keeping: kept).index
    }

    func moveSelection(by step: Int) {
        selected = CommandBarSelection(index: selected).moved(by: step, count: results.count).index
    }

    func reset() {
        results = []
        selected = nil
        hovered = nil
        query = ""
        footer = ""
        focusToken += 1
    }
}

/// The command bar: the search field, up to eight results of 36 points (the rest scroll), and the line of hints under them, on the panel's
/// background. A result is an icon (its picture) or an action (its symbol), its title with the characters the query matched in
/// `.semibold`, and its subtitle in secondary text.
///
/// It only draws. Keys are the panel's, and a click on a result goes to `activate` (an icon is clicked, an action is run).
struct CommandBarView: View {
    static let rowHeight = PanelMath.commandBarRowHeight
    private static let imageColumn: CGFloat = 28

    let model: CommandBarModel
    let images: ItemImages
    let activate: (Int) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            PanelBackgroundView(style: model.style)
            VStack(spacing: 0) {
                CommandBarSearchField(model: model)
                    .padding(.horizontal, 16)
                    .frame(height: PanelMath.commandBarFieldHeight)
                if !model.results.isEmpty {
                    Rectangle()
                        .fill(.separator)
                        .frame(height: PanelMath.commandBarDividerHeight)
                    list
                    Text(model.footer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .frame(height: PanelMath.commandBarFooterHeight)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: PanelBackgroundView.cornerRadius, style: .continuous))
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { place, result in
                        row(result, place: place).id(result.id)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.automatic)
            .frame(height: CGFloat(min(model.results.count, PanelMath.commandBarVisibleRows)) * Self.rowHeight)
            .onChange(of: model.selected) { _, selected in
                if let selected, let id = model.results[safe: selected]?.id { proxy.scrollTo(id) }
            }
        }
    }

    private func row(_ result: SearchResult, place: Int) -> some View {
        HStack(spacing: 8) {
            picture(of: result.candidate.kind)
                .frame(width: Self.imageColumn, height: Self.rowHeight - 8)
            title(of: result)
                .lineLimit(1)
            if let subtitle = result.candidate.subtitle {
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background {
            if model.selected == place {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor.opacity(0.2))
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5)
            } else if model.hovered == place {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .quaternaryLabelColor))
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.hovered = place } else if model.hovered == place { model.hovered = nil }
        }
        .onTapGesture { activate(place) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(result.candidate.title)
        .accessibilityValue(result.candidate.subtitle ?? "")
        .accessibilityAddTraits(model.selected == place ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { activate(place) }
    }

    @ViewBuilder
    private func picture(of kind: SearchResultKind) -> some View {
        switch kind {
        case .icon(let item):
            let image = images.image(for: item, appearance: colorScheme == .dark ? .dark : .light)
            let size = PanelMath.imageSize(natural: image.size, in: CGSize(width: Self.imageColumn, height: Self.rowHeight - 8))
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
        case .action(let action):
            Image(systemName: action.symbolName)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
    }

    private func title(of result: SearchResult) -> Text {
        var text = AttributedString()
        for run in CommandBarTitle.runs(of: result.candidate.title, matching: result.titleOffsets) {
            var part = AttributedString(run.text)
            if run.matched { part.font = .body.weight(.semibold) }
            text += part
        }
        return Text(text)
    }
}

/// The search field: an AppKit text field, so that the panel can give it the keyboard when it opens. It has no focus ring, and what is
/// typed goes to the model.
private struct CommandBarSearchField: NSViewRepresentable {
    static let placeholder = "Search icons and actions"

    let model: CommandBarModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.delegate = context.coordinator
        field.placeholderString = Self.placeholder
        field.setAccessibilityLabel(Self.placeholder)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        if field.stringValue != model.query, field.currentEditor() == nil { field.stringValue = model.query }
        if context.coordinator.focusToken != model.focusToken {
            context.coordinator.focusToken = model.focusToken
            field.stringValue = model.query
            field.takeFocus()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: CommandBarModel
        var focusToken = -1

        init(model: CommandBarModel) {
            self.model = model
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.query = field.stringValue
        }
    }
}

/// A text field that takes the keyboard when it is put in a window, and when it is asked to.
final class FocusingTextField: NSTextField {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        takeFocus()
    }

    /// On the next turn, so that the window is in place and key.
    func takeFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window else { return }
            window.makeFirstResponder(self)
        }
    }
}
