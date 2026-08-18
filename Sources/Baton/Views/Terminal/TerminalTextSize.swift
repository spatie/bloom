import AppKit
import SwiftUI

/// How large the built-in terminals are set.
///
/// A point size rather than a scale, because a terminal font size is a number the user already
/// has: it is the one in their Ghostty config, and every other terminal they own asks for it the
/// same way.
///
/// The stored value is an override, and no override is the normal state. Baton follows Ghostty's
/// `font-size` when there is one, and the system monospace size when there is not, so a terminal
/// opens at the size the user reads everywhere else. Diverging from that silently, because
/// somebody once pressed Cmd+Plus in a shell that no longer exists, would be worse than not having
/// the setting at all.
@MainActor
enum TerminalTextSize {
    /// Shared by the terminals and the stepper in Settings.
    static let defaultsKey = "terminal.fontSize"

    /// Small enough that a wide diff fits, large enough to read across a room, and neither end
    /// produces a shell you have to go to Settings to escape from: Cmd+0 is always the way back.
    static let range: ClosedRange<CGFloat> = 9...28

    /// One point per press, the way every other terminal steps. This used to be `Metrics.hairline`,
    /// which is half a point on a Retina display and a whole one everywhere else, so the shortcut
    /// did almost nothing and did a different almost-nothing depending on the screen.
    static let step: CGFloat = 1

    /// The size the user asked for, or nil to follow Ghostty.
    ///
    /// Zero on disk means "no override": `UserDefaults` already answers zero for a key nobody has
    /// written, so there is no separate "has been set" flag that could fall out of step with it.
    static var override: CGFloat? {
        get {
            let stored = CGFloat(UserDefaults.standard.double(forKey: defaultsKey))
            guard stored > 0 else { return nil }
            return min(max(stored, range.lowerBound), range.upperBound)
        }
        set {
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
                return
            }
            let clamped = min(max(newValue, range.lowerBound), range.upperBound)
            UserDefaults.standard.set(Double(clamped), forKey: defaultsKey)
        }
    }

    /// Cmd+Plus and Cmd+Minus. They step from what is on screen rather than from the stored value,
    /// so the first press off Ghostty's 14 lands on 15 and not on 10.
    static func adjust(from current: CGFloat, by delta: CGFloat) {
        override = current + delta
    }

    /// Ghostty's `font-size` for this appearance, when the user has one and has not turned the
    /// Ghostty theme off.
    static func ghosttyDefault(for appearance: NSAppearance) -> CGFloat? {
        guard UserDefaults.standard.object(forKey: TerminalGhostty.defaultsKey) as? Bool ?? true
        else { return nil }
        return TerminalGhostty.theme(for: appearance)?.fontSize.map { CGFloat($0) }
    }

    /// What a terminal opens at when nothing overrides it. The callout style rather than the body
    /// one, because that is the rung `Typo.code` sits on and a shell should not be a size apart
    /// from the code shown beside it.
    static var systemDefault: CGFloat {
        NSFont.preferredFont(forTextStyle: .callout).pointSize
    }

    static func fallback(for appearance: NSAppearance) -> CGFloat {
        ghosttyDefault(for: appearance) ?? systemDefault
    }
}
