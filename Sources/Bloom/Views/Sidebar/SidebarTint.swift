import SwiftUI
import AppKit

/// The sidebar's meaning colours, one step quieter than the system's.
///
/// The source list is a column of a dozen small marks read at a glance, all of them at once. The
/// system colours are tuned for a control that is the only saturated thing on its screen: a
/// `systemRed` cross, a `systemOrange` triangle and a `systemGreen` tick stacked eight rows apart
/// read as a warning light panel rather than as a quiet index of what each agent is doing. The
/// reference render this was measured against draws exactly the same states at roughly two thirds
/// the brightness in light and two thirds the saturation in dark, and it is legible where ours is
/// loud.
///
/// The transform is a CLAMP, not a scale, and that is deliberate. `Palette.positive` and friends
/// are being retuned elsewhere, and a colour that is multiplied down every time it passes through
/// here would drift a step quieter with each pass. A ceiling on saturation and a band for
/// brightness gives the same answer however many times it is applied and whatever the palette
/// underneath decides to become. Hue is never touched, so red stays red and a failure still reads
/// as a failure.
///
/// The two appearances move in opposite directions because the ground does. On white, quieting
/// means going darker: contrast against the page goes up, not down. On the dark ground it means
/// going paler and less saturated, which is also what keeps a blue or a teal from sinking into a
/// deep blue sidebar.
///
/// Candidate for promotion into `Theme.swift` as `Palette.positiveQuiet` and siblings, or as a
/// `Color.quieted` modifier. It lives here because the sidebar is the only place that has been
/// measured against the reference so far.
enum SidebarTint {
    /// Merged, and checks that passed.
    static let positive = quieted(Palette.positive)
    /// Checks that failed.
    static let negative = quieted(Palette.negative)
    /// Setup that failed, and checks still running.
    static let warning = quieted(Palette.warning)
    /// Waiting for the user: an unread turn, an open pull request.
    static let accent = quieted(Palette.accent)
    /// An agent mid turn.
    static let running = quieted(Palette.running)

    /// Saturation ceiling and brightness band, per appearance.
    ///
    /// Measured off the reference sidebar: light meaning colours land at S 74 to 90, B 48 to 70;
    /// dark ones at S 59 to 74, B 85 to 91. The light ceiling is loose because the system colours
    /// are already inside it there, and it is the brightness that has to come down.
    private static let lightSaturation: CGFloat = 0.92
    private static let lightBrightness: CGFloat = 0.66
    private static let darkSaturation: CGFloat = 0.66
    private static let darkBrightnessFloor: CGFloat = 0.78
    private static let darkBrightnessCeiling: CGFloat = 0.92

    /// Applied per appearance rather than once, because the colour handed in is usually dynamic:
    /// `controlAccentColor` is whatever the user picked, and the palette's own values differ
    /// between light and dark. Resolving it eagerly would freeze one appearance's answer into
    /// both.
    static func quieted(_ color: Color) -> Color {
        let base = NSColor(color)
        return Color(nsColor: NSColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance {
                resolved = base.usingColorSpace(.sRGB) ?? base
            }
            guard resolved.colorSpace.colorSpaceModel == .rgb else { return base }

            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            resolved.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if isDark {
                saturation = min(saturation, darkSaturation)
                brightness = min(max(brightness, darkBrightnessFloor), darkBrightnessCeiling)
            } else {
                saturation = min(saturation, lightSaturation)
                brightness = min(brightness, lightBrightness)
            }

            return NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
        })
    }
}

/// `+214 -38` at the trailing edge of a sidebar row.
///
/// A near copy of `DiffStatLabel`, and it should not stay one. It exists only because the counts
/// sit two glyph widths from the status mark on the same row, and a row whose mark has been
/// quieted while its numbers stay at full `systemGreen` reads as two different languages. The
/// shared label takes no tint, and `Theme.swift` is not this change's to edit. When `SidebarTint`
/// is promoted, `DiffStatLabel` should gain the tints and this type should go.
///
/// The abbreviation rule is not duplicated: it is `DiffStatLabel`'s, called here, so `1.2k` cannot
/// mean two different things in two places.
struct SidebarDiffStat: View {
    var additions: Int
    var deletions: Int

    @Environment(\.isOnEmphasizedSelection) private var isOnSelection

    var body: some View {
        HStack(spacing: Metrics.spacingSmall) {
            if additions > 0 {
                Text("+\(DiffStatLabel.abbreviate(additions))")
                    .foregroundStyle(isOnSelection ? Palette.selectedEmphasizedText : SidebarTint.positive)
            }
            if deletions > 0 {
                Text("-\(DiffStatLabel.abbreviate(deletions))")
                    .foregroundStyle(
                        isOnSelection
                            ? Palette.selectedEmphasizedText.opacity(0.75)
                            : SidebarTint.negative
                    )
            }
        }
        .font(Typo.codeSmall)
        .monospacedDigit()
    }
}
