import AppKit
import BloomCore

/// How large the built-in terminals are set.
///
/// A point size rather than a scale, because a terminal font size is a number the user already
/// has: it is the one in their Ghostty config, and every other terminal they own asks for it the
/// same way.
///
/// The stored value is an override, and no override is the normal state. Bloom follows Ghostty's
/// `font-size` when there is one, and the system monospace size when there is not, so a terminal
/// opens at the size the user reads everywhere else. Diverging from that silently, because
/// somebody once pressed Cmd+Plus in a shell that no longer exists, would be worse than not having
/// the setting at all.
@MainActor
enum TerminalTextSize {
    /// Small enough that a wide diff fits, large enough to read across a room, and neither end
    /// produces a shell you have to go to Settings to escape from: Cmd+0 is always the way back.
    static let range: ClosedRange<CGFloat> = 9...28
    /// One point per press, the way every other terminal steps. This used to be `Metrics.hairline`,
    /// which is half a point on a Retina display and a whole one everywhere else, so the shortcut
    /// did almost nothing and did a different almost-nothing depending on the screen.
    static let step: CGFloat = 1

    /// The size the user asked for, or nil to follow the default. Kept in the shared typography,
    /// so it survives a change of theme.
    static var override: CGFloat? {
        get { ColourThemePreference.shared.typographyOverrides.terminalTypography.fontSize.map { CGFloat($0) } }
        set {
            ColourThemePreference.shared.typographyOverrides.terminalTypography.fontSize = newValue.map {
                Double(min(max($0, range.lowerBound), range.upperBound))
            }
        }
    }

    /// Cmd+Plus and Cmd+Minus. They step from what is on screen rather than from the stored value,
    /// so the first press off Ghostty's 14 lands on 15 and not on 10.
    static func adjust(from current: CGFloat, by delta: CGFloat) {
        override = current + delta
    }

    /// Whether that step would land anywhere. `adjust` clamps, so at either end of the range the
    /// menu item would otherwise be enabled and do nothing, which is the one thing a size control
    /// must never do: the grey is how the user learns there is no more.
    static func canAdjust(from current: CGFloat, by delta: CGFloat) -> Bool {
        min(max(current + delta, range.lowerBound), range.upperBound) != current
    }

    /// What a terminal opens at when nothing overrides it. The callout style rather than the body
    /// one, because a shell should not be a size apart from the code shown beside it.
    static var systemDefault: CGFloat {
        NSFont.preferredFont(forTextStyle: .callout).pointSize
    }
}
