import SwiftUI

/// One row of a footer picker that opens a list instead of a menu: a tick column, the name, and
/// underneath it the sentence saying what picking it would do.
///
/// **The sentence is the whole point of the row.** The permission picker was an `NSMenu` with a
/// single greyed line at its foot describing whichever mode was already chosen, because an
/// `NSMenu` row is one line with no room under it. The owner read that and said "I cannot see
/// what the option does before picking it", which is exactly right and matters most here: the
/// four rows are how much a coding agent may do without asking, and Bypass permissions is a
/// decision to read before making rather than after.
///
/// The same shape as `QuickPromptRow`, deliberately, and for the reason that row's own head
/// gives: these are all a floating list somebody arrows through, and a second idiom for the third
/// one is how a window grows three.
struct ComposerOptionRow: View {
    var option: ComposerOption
    /// Whether this is the setting in force, which is what the tick means. It is not the same
    /// question as `isHighlighted`: arrowing down a menu moves the highlight and leaves the tick
    /// where it is, and a row that conflated the two would look like it had already been chosen.
    var isSelected: Bool
    /// Where the keyboard is, and where the pointer is: one highlight, driven by both.
    var isHighlighted: Bool
    var onPick: @MainActor () -> Void
    var onHover: @MainActor () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onPick) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing) {
                // The column is always taken, ticked or not, so the names line up down the list
                // the way an `NSMenu`'s state column lines them up. Drawn rather than left to the
                // platform, because a panel is not a menu and has no state column of its own.
                Image(systemName: "checkmark")
                    // Set at the name's own rung rather than scaled, so the tick sits on the
                    // first line's baseline in a row that is two lines tall. `AgentQuestionCard`
                    // draws its mark the same way beside the same shape of label.
                    .font(Typo.label)
                    .foregroundStyle(Palette.accent)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: Metrics.glyph, alignment: .leading)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                    Text(option.label)
                        // `label`, the rung the scale's own note calls the workhorse for row
                        // labels and anything scanned rather than read. `QuickPromptRow`,
                        // `FileMentionRow` and `SlashCommandRow` are all on it.
                        .font(Typo.label)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)

                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail)
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                            // Wrapped rather than truncated. These are the vendors' own sentences
                            // and the second half of one is where the qualification lives: "and
                            // run commands. Approval is required to reach the internet" is the
                            // part somebody is opening this picker to find.
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.spacing)
            // Wider than a one line row takes, because this one is two: at four points the name
            // sat against the top of its own highlight. The same number `QuickPromptRow` settled
            // on after the same complaint.
            .padding(.vertical, Metrics.spacingWide)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // One item to VoiceOver, not three. A `Button` is already a single element, so the label
        // and the value are named on it rather than the children being flattened underneath: the
        // name is what the row is called and the sentence is its value, which is what makes
        // "Bypass permissions, no further prompts, everything runs" one thing to hear before
        // choosing it. `QuickPromptRow` names its own the same way.
        .accessibilityLabel(option.label)
        .accessibilityValue(option.detail ?? "")
        // Which row is the setting in force, said rather than left to the tick, because the tick
        // is a glyph and is hidden from VoiceOver above.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // The quiet fill rather than the accent one, which is the same call `QuickPromptRow`
        // makes and for the same reason: the row in force is highlighted the instant the panel
        // opens, before anybody has done anything, and at full accent that reads as a choice
        // already made rather than as the place Return will go.
        .rowBackground(isSelected: isHighlighted, isHovered: isHovered, isFocused: false)
        .onHover { hovering in
            isHovered = hovering
            if hovering { onHover() }
        }
    }
}
