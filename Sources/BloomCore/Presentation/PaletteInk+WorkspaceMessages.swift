import Foundation
import BloomClient

/// The colours of a message between workspaces, beside `PaletteInk` rather than inside it.
///
/// An extension in a file of its own because `PaletteInk.swift` is also being moved into a
/// package on the server runtime branch, and every line added to it on main was a conflict there
/// copied across by hand. The values and their reasons are unchanged: see `Palette.workspaceMessage`
/// for why the hue is Starfish orange, and `PaletteContrastTests` for what holds it.
extension PaletteInk {
    public static let workspaceMessage = Pair(light: 0xA04F00, dark: 0xF7AE5C)
    public static let workspaceMessageFill = Pair(light: 0xF7AE5C, dark: 0xEDA04C)
    public static let workspaceMessageInk = Pair(light: 0x3D2100, dark: 0x3D2100)
}
