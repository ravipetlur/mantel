import Foundation

/// A colour as the settings keep it: red, green, blue and alpha, each from 0 to 1.
///
/// A component that is missing from a file takes its default (black, fully opaque), and one that is outside 0 to 1 is brought
/// into it, so a file edited by hand can't make a colour the drawing code doesn't expect.
public struct RGBAColor: Codable, Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// A colour with each component brought into 0 to 1 (a component that isn't a number becomes 0). For a colour that comes from a
    /// picker, whose colour space can hold more than the settings do.
    public init(clamping red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.init(red: Self.clamped(red), green: Self.clamped(green), blue: Self.clamped(blue), alpha: Self.clamped(alpha))
    }

    static let black = RGBAColor(red: 0, green: 0, blue: 0)
    static let white = RGBAColor(red: 1, green: 1, blue: 1)

    private enum CodingKeys: String, CodingKey {
        case red, green, blue, alpha
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        red = Self.clamped(try container.decodeIfPresent(Double.self, forKey: .red) ?? 0)
        green = Self.clamped(try container.decodeIfPresent(Double.self, forKey: .green) ?? 0)
        blue = Self.clamped(try container.decodeIfPresent(Double.self, forKey: .blue) ?? 0)
        alpha = Self.clamped(try container.decodeIfPresent(Double.self, forKey: .alpha) ?? 1)
    }

    /// A component within 0 to 1: the nearest end of the range for one outside it, and 0 for one that isn't a number.
    static func clamped(_ component: Double) -> Double {
        component.isNaN ? 0 : min(max(component, 0), 1)
    }
}
