import AppKit
import BloomCore

@MainActor
enum TerminalTextSize {
    static let range: ClosedRange<CGFloat> = 9...28
    static let step: CGFloat = 1

    static var override: CGFloat? {
        get { ColourThemePreference.shared.overrides.terminalTypography.fontSize.map { CGFloat($0) } }
        set {
            ColourThemePreference.shared.overrides.terminalTypography.fontSize = newValue.map {
                Double(min(max($0, range.lowerBound), range.upperBound))
            }
        }
    }

    static func adjust(from current: CGFloat, by delta: CGFloat) {
        override = current + delta
    }

    static func canAdjust(from current: CGFloat, by delta: CGFloat) -> Bool {
        min(max(current + delta, range.lowerBound), range.upperBound) != current
    }

    static var systemDefault: CGFloat {
        NSFont.preferredFont(forTextStyle: .callout).pointSize
    }
}
