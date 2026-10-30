import AppKit
import MKCore
import SwiftUI

extension RGBAColor {
    /// A colour the person chose in a colour picker, as the settings keep it (sRGB).
    init(_ color: Color) {
        let converted = NSColor(color).usingColorSpace(.sRGB) ?? .black
        // A colour the picker holds in a wider space than sRGB can come out of range: the package brings it in.
        self.init(clamping: Double(converted.redComponent), green: Double(converted.greenComponent), blue: Double(converted.blueComponent),
                  alpha: Double(converted.alphaComponent))
    }
}

/// A colour picker that saves each change at once: a colour isn't a typed number, so there is nothing to wait for.
struct SettingsColorPicker: View {
    private let title: String
    private let showsTitle: Bool
    private let color: RGBAColor
    private let change: (RGBAColor) -> Void

    /// `showsTitle` false is a colour well beside a switch with a title of its own; this one is still what Accessibility says.
    init(_ title: String, showsTitle: Bool = true, color: RGBAColor, change: @escaping (RGBAColor) -> Void) {
        self.title = title
        self.showsTitle = showsTitle
        self.color = color
        self.change = change
    }

    var body: some View {
        let picker = ColorPicker(title, selection: Binding(
            get: { PanelBackgroundView.color(color) },
            set: { change(RGBAColor($0)) }), supportsOpacity: true)
        if showsTitle {
            picker
        } else {
            picker.labelsHidden()
        }
    }
}

/// How the second bar will look, drawn by the same view the bar draws its background with, behind four placeholder cells. The
/// previewed light or dark is set on the AppKit view that hosts the drawing, because the visual effect views follow that, not SwiftUI's
/// scheme. The panel's shadow isn't drawn here: it would show through the translucent styles, which a real panel's doesn't.
struct PanelStylePreview: View {
    static let size = CGSize(width: 300, height: 60)

    let style: PanelStyle
    @Environment(\.colorScheme) private var windowScheme

    var body: some View {
        AppearanceHost(appearance: appearance, scheme: scheme) {
            ZStack {
                PanelBackgroundView(style: style)
                HStack(spacing: SecondBarPreviewMetrics.spacing) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: IconBarView.cellRadius, style: .continuous)
                            .fill(Color.primary.opacity(0.25))
                            .frame(width: SecondBarPreviewMetrics.cellWidth, height: SecondBarPreviewMetrics.cellHeight)
                    }
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityHidden(true)
    }

    /// Light and dark are the panel's own when it has chosen; one that follows the menu bar is drawn as the window is.
    private var scheme: ColorScheme {
        switch style.appearance {
        case .light: .light
        case .dark: .dark
        case .matchMenuBar: windowScheme
        }
    }

    private var appearance: NSAppearance? {
        switch style.appearance {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .matchMenuBar: nil
        }
    }
}

/// SwiftUI content hosted in an AppKit view with its own appearance (nil: the window's), so that the visual effect views inside it are
/// drawn light or dark as asked.
private struct AppearanceHost<Content: View>: NSViewRepresentable {
    let appearance: NSAppearance?
    let scheme: ColorScheme
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let view = NSHostingView(rootView: root)
        view.appearance = appearance
        return view
    }

    func updateNSView(_ view: NSHostingView<AnyView>, context: Context) {
        view.rootView = root
        if view.appearance?.name != appearance?.name { view.appearance = appearance }
    }

    /// The size SwiftUI proposes (the preview's fixed frame), so the background fills it.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<AnyView>, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: PanelStylePreview.size)
    }

    private var root: AnyView {
        AnyView(content.environment(\.colorScheme, scheme))
    }
}

private enum SecondBarPreviewMetrics {
    static let cellWidth: CGFloat = 36
    static let cellHeight: CGFloat = 26
    static let spacing: CGFloat = 8
}
