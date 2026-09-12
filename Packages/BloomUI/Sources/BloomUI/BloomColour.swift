import SwiftUI
import BloomClient

/// Resolves the desktop's tested palette values without depending on AppKit or UIKit.
enum BloomColour {
    static func resolve(_ pair: PaletteInk.Pair, scheme: ColorScheme) -> Color {
        let value = pair.member(dark: scheme == .dark)
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }
}
