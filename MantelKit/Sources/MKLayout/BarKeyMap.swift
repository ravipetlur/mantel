import CoreGraphics

extension BarKey {
    /// The key a panel's key event stands for: nil for any other key, which the panel passes on.
    ///
    /// - Parameters:
    ///   - keyCode: the key's virtual key code (`NSEvent.keyCode`).
    ///   - shift, option, command: the modifiers that were held.
    public static func forKeyCode(_ keyCode: UInt16, shift: Bool = false, option: Bool = false, command: Bool = false) -> BarKey? {
        switch keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        case 115: .home
        case 119: .end
        case 48: .tab(backwards: shift)
        case 36, 76: .forReturn(option: option, command: command)
        case 53: .escape
        default: nil
        }
    }
}

extension PanelMath {
    /// The size a cell draws its picture at: the picture's own size in points, scaled down to fit the cell with `inset` to spare on every
    /// side, and never scaled up.
    public static func imageSize(natural: CGSize, in cell: CGSize, inset: CGFloat = 2) -> CGSize {
        guard natural.width > 0, natural.height > 0 else { return .zero }
        let room = CGSize(width: max(0, cell.width - 2 * inset), height: max(0, cell.height - 2 * inset))
        let scale = min(1, room.width / natural.width, room.height / natural.height)
        return CGSize(width: natural.width * scale, height: natural.height * scale)
    }
}
