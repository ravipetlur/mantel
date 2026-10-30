import AppKit
import MKCore
import MKLayout
import SwiftUI

/// What is drawn behind the icons of a panel, and its border: the second bar's and a group panel's look (`PanelStyle`). The panel's
/// corners are 10 points, continuous, and the picture inside Settings that shows the look uses this same view.
///
/// - **The background** is the menu bar's own look (a menu's material, behind the window), the system's glass (tinted when a colour is
///   given), one of the materials, one colour or a gradient.
/// - **The border** is the person's own, or a 1 pixel line in the separator colour.
/// - **Light or dark** is the window's appearance, not this view's: the panel sets it (`PanelStyle.appearance`).
struct PanelBackgroundView: View {
    /// The corner radius of every floating panel.
    static let cornerRadius: CGFloat = 10

    let style: PanelStyle
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        background
            .clipShape(shape)
            .overlay { border(shape) }
    }

    @ViewBuilder
    private var background: some View {
        switch style.background {
        case .matchMenuBar:
            VisualEffectBackground(material: .menu)
        case .glass(let tint):
            GlassBackground(tint: tint.map(Self.nsColor))
        case .material(let thickness):
            Rectangle().fill(Self.material(thickness))
        case .solid(let color):
            Rectangle().fill(Self.color(color))
        case .gradient(let from, let to, let angle):
            let line = PanelMath.gradientPoints(angle: angle)
            Rectangle().fill(LinearGradient(colors: [Self.color(from), Self.color(to)], startPoint: UnitPoint(x: line.start.x, y: line.start.y),
                                            endPoint: UnitPoint(x: line.end.x, y: line.end.y)))
        }
    }

    private func border(_ shape: RoundedRectangle) -> some View {
        Group {
            if let border = style.border {
                shape.strokeBorder(Self.color(border.color), lineWidth: CGFloat(border.width))
            } else {
                shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1 / max(displayScale, 1))
            }
        }
    }

    private static func material(_ thickness: MaterialThickness) -> Material {
        switch thickness {
        case .ultraThin: .ultraThinMaterial
        case .thin: .thinMaterial
        case .regular: .regularMaterial
        case .thick: .thickMaterial
        case .ultraThick: .ultraThickMaterial
        }
    }

    static func color(_ color: RGBAColor) -> Color {
        Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }

    static func nsColor(_ color: RGBAColor) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

/// The menu bar's look: a menu's material, drawn from what is behind the window, active whether or not Mantel is.
private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// The system's glass, with a tint when the person chose one.
private struct GlassBackground: NSViewRepresentable {
    let tint: NSColor?

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = PanelBackgroundView.cornerRadius
        view.tintColor = tint
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.tintColor = tint
    }
}
