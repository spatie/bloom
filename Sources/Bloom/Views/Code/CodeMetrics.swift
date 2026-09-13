import AppKit
import BloomCore
import SwiftUI

@MainActor
struct CodeMetrics {
    private let face: NSFont
    private let numbers: NSFont
    private let characterWidth: CGFloat
    private let digitWidth: CGFloat
    private let naturalHeight: CGFloat
    private let height: CGFloat

    private static var cachedTypography: ThemeTypography?
    private static var cached: Self?

    static var current: Self {
        let typography = ColourThemePreference.shared.codeTypography
        if typography == cachedTypography, let cached { return cached }
        let value = Self(typography: typography)
        cachedTypography = typography
        cached = value
        return value
    }

    private init(typography: ThemeTypography) {
        face = TerminalGhostty.font(family: typography.fontFamily, size: CGFloat(typography.fontSize ?? 13))
        numbers = NSFont.monospacedDigitSystemFont(ofSize: max(9, face.pointSize - 2), weight: .regular)
        characterWidth = max(1, ("0" as NSString).size(withAttributes: [.font: face]).width)
        digitWidth = max(1, ("0" as NSString).size(withAttributes: [.font: numbers]).width)
        naturalHeight = ceil(face.ascender - face.descender + face.leading)
        height = max(16, ceil(naturalHeight * CGFloat(typography.lineHeight ?? 1.2)))
    }

    static var font: NSFont { current.face }
    static var numberFont: NSFont { current.numbers }
    // Fixed point sizes keep SwiftUI's line spacing aligned with the gutter.
    static var measuredFont: Font { Font(font) }
    static var advance: CGFloat { current.characterWidth }
    static var numberAdvance: CGFloat { current.digitWidth }
    static var naturalLineHeight: CGFloat { current.naturalHeight }
    static var rowHeight: CGFloat { current.height }
    static var rowSpacing: CGFloat { rowHeight - naturalLineHeight }
    static var markerWidth: CGFloat { ceil(advance) + 4 }
    static var numberWidth: CGFloat { ceil(numberAdvance * 4) + gutterPadding }
    static let gutterPadding: CGFloat = 4
    static let textInset: CGFloat = 8
    static func columns(of line: String) -> Int { CodeColumns.count(of: line) }
}
