import AppKit
import BatonCore
import SwiftTerm

/// Baton's side of the user's Ghostty configuration: reads it once, then hands out AppKit and
/// SwiftTerm values.
@MainActor
enum TerminalGhostty {
    /// Shared by the terminal and the switch in Settings. It defaults to on: following the
    /// terminal the user already configured beats inventing a second look, and a machine without
    /// Ghostty is unaffected either way.
    static let defaultsKey = "useGhosttyTerminalTheme"

    /// Read once per appearance per launch. Ghostty itself only re-reads on an explicit reload, and
    /// every terminal in the window asks for this on every appearance change, so re-reading four
    /// files each time would buy nothing.
    private static var cache: [GhosttyAppearance: GhosttyTheme?] = [:]

    static func theme(for appearance: NSAppearance) -> GhosttyTheme? {
        let key: GhosttyAppearance =
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        if let cached = cache[key] { return cached }

        let loaded = GhosttyConfigLoader.load(appearance: key)
        cache[key] = loaded
        return loaded
    }

    /// The named font at the given size, or the monospaced system font when the user's font is not
    /// installed. `NSFont(name:)` returns nil rather than substituting, so an uninstalled font
    /// would otherwise leave the terminal without a font at all.
    static func font(family: String?, size: CGFloat) -> NSFont {
        guard let family, !family.isEmpty, let font = NSFont(name: family, size: size) else {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return font
    }
}

extension NSColor {
    /// Ghostty's hex values are sRGB, and creating the colour in that space keeps the bytes the
    /// user wrote rather than reinterpreting them in the display's space.
    convenience init(_ color: GhosttyColor) {
        self.init(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
    }
}

extension SwiftTerm.Color {
    convenience init(_ color: GhosttyColor) {
        self.init(
            red8: UInt16(color.red),
            green8: UInt16(color.green),
            blue8: UInt16(color.blue)
        )
    }
}
