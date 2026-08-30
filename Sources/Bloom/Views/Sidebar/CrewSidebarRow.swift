import SwiftUI
import BloomCore

/// One crew member in the source list, indented a step under the workspace it shares a worktree
/// with.
///
/// **A dot and a name, and no word.** The owner asked for exactly that: "working", "asks you" and
/// the rest are noise once you have read them twice, and a crew member's name is the thing you are
/// looking for in the column. The mark says what the agent is doing, in the same shapes and the
/// same tints the workspace row above it already uses, so the pane says "working" and "waiting on
/// you" in one shape throughout.
///
/// **It is not `SubagentSidebarRow`, and the two must not be merged.** That row is a child of one
/// turn: it is drawn from the live stream, it never reaches the database and it is gone by the
/// next launch, which is why it can afford a readout of seconds and tokens that expires with it.
/// This one is a `Session` row that outlives the turn that asked for it and is still here
/// tomorrow. See `Crew`, whose head argues the difference and says why the word here is "crew".
struct CrewSidebarRow: View {
    var row: CrewRow

    @Environment(\.backgroundProminence) private var prominence

    /// Whether the row is sitting on the accent selection fill, where the meaning colours are
    /// unreadable and the shape has to carry the meaning alone. Read exactly as `WorkspaceRow` and
    /// `SubagentSidebarRow` read it, so no two rows in this column can disagree about what a
    /// selected row looks like.
    private var isOnSelection: Bool { prominence == .increased }

    var body: some View {
        Label {
            Text(row.name)
                .font(Typo.caption)
                .foregroundStyle(isOnSelection ? Palette.textInverted : Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            CrewMarkGlyph(state: row.state, isOnSelection: isOnSelection)
        }
        .labelStyle(SidebarRowLabelStyle())
        // The mark starts where the workspace's NAME starts, which is what makes the nesting
        // read. The owner asked for it off a capture of the first arrangement, where the mark sat
        // between the workspace's mark and its name: a third column, close enough to both to look
        // like neither, and the row read as a sibling of the workspace rather than as something
        // under it. On the name column it is unambiguous, because the only thing above it in that
        // column is the name of the thing it belongs to.
        .padding(.leading, SidebarMetrics.crewIndent)
        // The dot is the fact a sighted reader gets for free and a screen reader gets not at all,
        // and here it is the ONLY thing carrying the state: the row deliberately has no word on it.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(row.name))
        .accessibilityValue(Text(row.spokenState))
        .accessibilityCustomContent(Text("Subagent"), Text(row.name), importance: .high)
        // What the row does not say out loud, said on hover. The state is worth a sentence when
        // somebody goes looking for it, which is not the same as it being worth a column.
        .help("\(row.name): \(row.spokenState)")
    }
}

/// What the sidebar draws for one crew member, which is its name and what it is doing.
///
/// **A projection of `Session` rather than the row itself**, and that is a performance decision.
/// `Session` carries `updatedAt`, two token counts, a cost and a context size, and every one of
/// those is rewritten as an agent works. Mirrored whole in `AppModel.crewRows`, a turn would
/// invalidate every sidebar row in the window several times a second to redraw a name that had
/// not moved. Three fields that only change when the row's drawing changes is what makes the
/// equality check in `noteCrewChanged` worth doing.
struct CrewRow: Identifiable, Equatable {
    var id: SessionID
    /// The name the orchestrator invented, straight out of `Session.title`. See `Crew`: Bloom
    /// takes no view on what a crew member may be called beyond its length.
    var name: String
    var state: SessionState

    init(_ session: Session) {
        id = session.id
        name = session.title
        state = session.state
    }

    /// The word the row does not print, for VoiceOver and for the hover. The states are the
    /// session's own, said in the vocabulary the rest of the window already uses for them.
    var spokenState: String {
        switch state {
        case .idle: "Waiting for work"
        case .running: "Working"
        case .waiting: "Asking you something"
        case .failed: "Stopped with an error"
        case .cancelled: "Stopped"
        }
    }
}

/// The mark at the leading edge of a crew member's row.
///
/// The running case is `WorkspaceRunningGlyph`, the same dot the workspace above it draws and on
/// the same clock, because `BusyPulse` is what keeps every lit row in the column pulsing together.
/// A second moving figure with a phase of its own would be the one thing this pane cannot have.
///
/// The four still marks differ in SHAPE before they differ in colour, which is the rule the whole
/// column is drawn to: a raised hand, a cross, a dash and a ring are told apart by someone who
/// cannot tell the amber one from the red one. The raised hand is `WorkspaceStatusGlyph`'s own
/// mark for the same state, so a crew member asking a question and a workspace asking one are one
/// shape.
struct CrewMarkGlyph: View {
    var state: SessionState
    var isOnSelection = false

    var body: some View {
        content
            .frame(width: Metrics.glyph, height: Metrics.glyph)
    }

    @ViewBuilder
    private var content: some View {
        if state == .running {
            WorkspaceRunningGlyph(isOnSelection: isOnSelection)
        } else {
            Image(systemName: Self.symbol(for: state))
                .font(Typo.micro)
                // Pinned for the reason `WorkspaceStatusGlyph` pins it: `SidebarRowLabelStyle`
                // raises `imageScale` for the list's icon slot, and left to the environment a
                // crew member's mark came out wider than the workspace's above it, which reads as
                // the child outranking its parent.
                .imageScale(.medium)
                .foregroundStyle(isOnSelection ? Palette.textInverted : Self.tint(for: state))
                // The shapes are distinct and the tints are distinct, and neither reaches
                // VoiceOver on its own.
                .accessibilityHidden(true)
        }
    }

    static func symbol(for state: SessionState) -> String {
        switch state {
        case .running: ""
        // The same filled hand the workspace rows, the menu bar strip and the opened ask row use,
        // so the four places this is reported say it with one mark.
        case .waiting: "hand.raised.fill"
        case .failed: "xmark"
        // Not a cross. Nothing went wrong: somebody stopped the agent, and a cross beside a row
        // nobody's code broke costs ten minutes.
        case .cancelled: "minus"
        // A ring rather than a disc. `circle.fill` at this size is the unread mark, which is a
        // claim about work waiting to be read; an idle crew member is an agent between turns and
        // is claiming nothing.
        case .idle: "circle"
        }
    }

    static func tint(for state: SessionState) -> Color {
        switch state {
        // The caution colour a workspace's raised hand already takes, and not the alarm red:
        // nothing has gone wrong, something is being asked.
        case .waiting: Palette.warning
        case .failed: Palette.negative
        case .running, .cancelled, .idle: Palette.textTertiary
        }
    }
}
