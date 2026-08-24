import SwiftUI
import BloomCore

/// One subagent in the source list, indented a step under the workspace that spawned it.
///
/// **It stays for the turn.** The row appears when the subagent starts, breathes while it works,
/// and when it ends it keeps its place carrying a tick, a cross or a dash and what it answered.
/// It goes when the next turn starts. The version that removed the row on completion looked
/// better in a screenshot and was unusable: three rows leaving one by one take everything below
/// them up the pane while you are reading the third. See `SubagentRoster` for the rule and
/// `SubagentRow` for what each state says.
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
        // One step past the workspace rows, which are themselves one step past the project. A
        // third level, and the last one this pane gets: see `SubagentRow.rows` for why depth past
        // one is drawn here rather than a step further in.
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
/// The running case is `WorkspaceRunningGlyph`, the same figure the workspace above it draws and
/// on the same clock, because `BusyPulse` is what keeps every lit row in the column breathing
/// together. A second moving figure with a phase of its own would be the one thing this pane
/// cannot have.
///
/// The three endings differ in SHAPE before they differ in colour, which is the rule the whole
/// column is drawn to: a tick, a cross and a dash are told apart by someone who cannot tell the
/// red one from the green one.
struct SubagentMarkGlyph: View {
    var mark: SubagentRow.Mark
    var isOnSelection = false

    var body: some View {
        content
            .frame(width: Metrics.glyph, height: Metrics.glyph)
    }

    @ViewBuilder
    private var content: some View {
        switch mark {
        case .working:
            WorkspaceRunningGlyph(isOnSelection: isOnSelection)
        default:
            Image(systemName: Self.symbol(for: mark))
                .font(Typo.micro)
                .foregroundStyle(isOnSelection ? Palette.textInverted : Self.tint(for: mark))
        }
    }

    static func symbol(for mark: SubagentRow.Mark) -> String {
        switch mark {
        case .working: ""
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
        case .working, .stopped: Palette.textTertiary
        }
    }
}
