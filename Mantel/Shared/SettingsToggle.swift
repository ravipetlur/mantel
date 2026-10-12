import SwiftUI

/// A switch in Settings, with its title as the switch's own accessibility label.
///
/// In a grouped form the visible text is drawn as a label beside the switch, and isn't the switch's own: the switch that Accessibility
/// reaches has no title and no description, and VoiceOver can't say what it is for. So every switch in the app is made here, and the
/// title is given to the switch itself. Nothing about how it looks changes.
struct SettingsToggle: View {
    private let title: String
    private let isOn: Binding<Bool>

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self.isOn = isOn
    }

    var body: some View {
        Toggle(title, isOn: isOn)
            .accessibilityLabel(title)
    }
}
