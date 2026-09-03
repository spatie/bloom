import SwiftUI
import BloomCore

/// One subagent in the source list, indented a step under the workspace that spawned it.
///
/// **It appears when the subagent starts, breathes while it works, and mostly goes when it is
/// done.** A tick is held long enough to be seen and then leaves; a cross stays, because it is the
/// only place a piece of a fan-out dying is visible at a glance; a row somebody has opened stays
/// while they are reading it; and the next turn clears whatever is left. See `SubagentRetention`
/// for that argument in full, `SubagentRoster` for the backstop and `SubagentRow` for what each
/// state says.
///
/// Everything drawn here is decided in `SubagentRow`, in the core, where the suite can reach it.
/// What is left in this file is a mark, a name, a readout and an indent.
struct SubagentSidebarRow: View {
    var row: SubagentRow

    @Environment(\.backgroundProminence) private var prominence

    /// Whether the row is sitting on the accent selection fill, where the meaning colours are
    /// unreadable and the shape has to carry the meaning alone. Read exactly as `WorkspaceRow`
    /// reads it, so the two rows cannot disagree about what a selected row looks like.
    private var isOnSelection: Bool { prominence == .increased }

    var body: some View {
        Label {
            HStack(spacing: Metrics.spacingSmall) {
                Text(row.title)
                    .font(Typo.caption)
                    .foregroundStyle(isOnSelection ? Palette.textInverted : Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: Metrics.spacingSmall)

                if !row.detail.text.isEmpty {
                    Text(row.detail.text)
                        .font(Typo.micro)
                        .monospacedDigit()
                        .foregroundStyle(
                            isOnSelection ? Palette.textInverted.opacity(0.8) : Palette.textTertiary
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // The name is what you are looking for and the readout is what you glance
                        // at, so the readout is the half that gives way when the pane is narrow.
                        .layoutPriority(-1)
                }
            }
        } icon: {
            SubagentMarkGlyph(mark: row.mark, isOnSelection: isOnSelection)
        }
        .labelStyle(SidebarRowLabelStyle())
        // One step past the workspace rows, which do not step in from the project at all: they
        // share its name column, so this indent is the only thing in the pane saying a subagent
        // is inside its workspace. The last level this pane gets: see `SubagentRow.rows` for why
        // depth past one is drawn here rather than a step further in.
        .padding(.leading, SidebarMetrics.rowIndent + SidebarMetrics.subagentIndent)
        // The mark is the fact a sighted reader gets for free and a screen reader gets not at all.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(row.title))
        .accessibilityValue(Text(row.spokenValue))
        .accessibilityCustomContent(Text("Subagent"), Text(row.title), importance: .high)
        .help(row.spokenValue)
    }
}

/// The mark at the leading edge of a subagent's row.
///
/// **All four differ in SHAPE before they differ in colour**, which is the rule the whole column
/// is drawn to: a tick, a cross, a dash and an ellipsis are told apart by somebody who cannot tell
/// the red one from the green one.
///
/// The working one used to be `WorkspaceRunningGlyph`, the pulsing disc the workspace row draws,
/// and it was the one mark in this pane that broke the rule. That file says so itself: the unread
/// mark in the same column is `circle.fill`, so the two were told apart by size, by hue and by
/// whether they moved, and in a still they were one dot. The report was a person looking at seven
/// working subagents and reading a blue dot as a badge: "so i think it is not busy, but it is
/// busy". An ellipsis is what every other surface uses for "going on", it is nothing like a
/// badge, and it sits in the same box at the same weight as the tick and the cross beside it.
///
/// It still breathes, and on the window's own heartbeat: `BreathingMark` rides `BusyPulse`, which
/// is what keeps every lit mark in the window on one clock. A second moving figure with a phase of
/// its own would be the one thing this pane cannot have.
struct SubagentMarkGlyph: View {
    var mark: SubagentRow.Mark
    var isOnSelection = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .frame(width: Metrics.glyph, height: Metrics.glyph)
    }

    @ViewBuilder
    private var content: some View {
        switch mark {
        case .working:
            BreathingMark(isMoving: !reduceMotion) { symbol }
        default:
            symbol
        }
    }

    private var symbol: some View {
        Image(systemName: Self.symbol(for: mark))
            .font(Typo.micro)
            // Pinned for the reason `WorkspaceStatusGlyph` pins it, and pinned here as well
            // because these rows ride the same `SidebarRowLabelStyle`: without it a subagent's
            // tick came out WIDER than the workspace's above it, which reads as the child
            // outranking its parent. A rung down in type is the step this row is meant to be.
            .imageScale(.medium)
            .foregroundStyle(isOnSelection ? Palette.textInverted : Self.tint(for: mark))
            // The shapes are distinct and the tints are distinct, and neither reaches
            // VoiceOver: it read the subagent's name and never said the thing had failed.
            .accessibilityLabel(mark.word)
    }

    static func symbol(for mark: SubagentRow.Mark) -> String {
        switch mark {
        // Not a disc. See the head of this type.
        case .working: "ellipsis"
        case .done: "checkmark"
        case .failed: "xmark"
        // Not a cross. Nothing went wrong: the turn ended and took its children with it, and a
        // cross beside a row nobody's code broke costs somebody ten minutes.
        case .stopped: "minus"
        }
    }

    static func tint(for mark: SubagentRow.Mark) -> Color {
        switch mark {
        // The accent is the palette's "this went well"; it has no green of its own. Same colour
        // the workspace column already draws a passing check in.
        case .done: Palette.positive
        case .failed: Palette.negative
        // The colour the whole window paints work in progress, which is what keeps this mark in
        // the family it left when it stopped being a disc.
        case .working: Palette.running
        case .stopped: Palette.textTertiary
        }
    }
}
