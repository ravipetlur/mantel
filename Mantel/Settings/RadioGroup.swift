import SwiftUI

/// One choice of a `RadioGroup`: what it is called, a line saying what it does, and whether it can be chosen.
struct RadioOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    let caption: String
    var isEnabled = true

    var id: Value { value }
}

/// A radio group whose every choice has a line of explanation under it, for Settings panes where a choice needs its consequence said.
///
/// A choice that can't be chosen is dimmed and does nothing, but its line stays as legible as any other: it is where the reason is. The
/// one that is selected shows so even when it can't be chosen (it is the saved choice, which may not be usable now).
///
/// To VoiceOver it is a native radio group (`accessibilityRepresentation`), each choice's line its hint.
struct RadioGroup<Value: Hashable>: View {
    /// What the group is called: for the accessibility tools, and in the pane too when `showsLabel` (a group that has no heading of its own).
    let label: String
    var showsLabel = false
    let options: [RadioOption<Value>]
    @Binding var selection: Value

    /// The width of the radio mark and the space after it: the line under a choice is indented by it, to sit under the title.
    private static var markWidth: CGFloat { 16 }
    private static var markSpacing: CGFloat { 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsLabel {
                Text(label)
                    .fontWeight(.medium)
                    // The group is named once, by the group (below): the visible name isn't another element to hear.
                    .accessibilityHidden(true)
            }
            ForEach(options) { option in
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        selection = option.value
                    } label: {
                        HStack(spacing: Self.markSpacing) {
                            Image(systemName: option.value == selection ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(option.value == selection ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .frame(width: Self.markWidth)
                                .accessibilityHidden(true)
                            Text(option.title)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!option.isEnabled)

                    Text(option.caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Self.markWidth + Self.markSpacing)
                }
            }
        }
        // The accessibility tools get one native radio group, named once, with the choices that can't be chosen dimmed: what they hear
        // is what a radio `Picker` says, not a stack of buttons.
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(options) { option in
                    Text(option.title)
                        .tag(option.value)
                        .disabled(!option.isEnabled)
                        .accessibilityHint(option.caption)
                }
            }
            .pickerStyle(.radioGroup)
        }
    }
}
