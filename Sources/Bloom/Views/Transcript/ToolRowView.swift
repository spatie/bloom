import SwiftUI
import BloomCore

/// One tool call: a line that says what happened, and everything behind it when opened.
struct ToolRowView: View {
    var use: AgentToolUse
    /// How the header draws this call: its glyph, its label, its detail and its chips.
    ///
    /// Handed down rather than worked out here, and that is a performance decision. This view holds
    /// its own `isHovered`, so its body runs twice for a pointer crossing the row and again on
    /// every pass of the transcript's list, and `TranscriptPresenter.present` is a full
    /// `CodexItem.decode` for a Codex call and a line count over a whole written file for a
    /// `Write`. The row that knows this row's identity is the one that can keep the answer. See
    /// `TranscriptPresentationCache`.
    var presentation: ToolPresentation
    /// Which worktree the call's paths are relative to, so a file chip in the header knows where
    /// it opens.
    var home: TranscriptHome
    var result: AgentToolResult?
    var isError: Bool
    /// Set when the call never ran. A refusal is drawn as one throughout: not the red a failure
    /// gets, because nothing failed. See `ToolRefusal`.
    var refusal: ToolRefusal?
    /// What the CLI said about the refusal, in one line.
    var refusalReason: String = ""
    var durationMS: Int?
    /// See `ToolRowHeader.subagentActions`.
    var subagentActions: Int?
    /// Opens the subagent's run, for an Agent call that has one. When set, the row's title and
    /// count open the run and the chevron alone expands the brief and result: two things a click
    /// can mean, so two places to click. See `ToolRowHeader`.
    var onOpenRun: (() -> Void)?
    /// An Agent call whose run was not kept, which the row says instead of offering to open it.
    var runUnavailable = false
    var isExpanded: Bool
    var onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onOpenRun {
                // No row-wide button here: the header draws its own two, and a button around them
                // would take every click for the toggle.
                header(onOpenRun: onOpenRun)
                    .accessibilityElement(children: .contain)
                    .accessibilityAction(named: SubagentRunLink.openActionName, onOpenRun)
            } else {
                ExpandableRowHeader(isExpanded: isExpanded, onToggle: onToggle) {
                    header(onOpenRun: nil)
                }
            }

            if isExpanded {
                ToolDetailView(use: use, result: result, refusal: refusal, refusalReason: refusalReason)
                    .padding(.leading, TranscriptLayout.detailIndent)
                    .padding(.trailing, TranscriptLayout.inset)
                    .padding(.bottom, TranscriptLayout.block)
                    // Opacity alone, and the height is the animation. The block is inserted at
                    // its full size and the row grows into it, so the detail fades up as the room
                    // for it appears; a `.move` here would slide the text against an edge that is
                    // itself moving, which reads as two animations disagreeing. The unfold is
                    // started by `TranscriptListView.toggle`, which owns `expanded`.
                    .transition(.opacity)
            }
        }
        .modifier(ExpandableRow(isHovered: isHovered))
        .onHover { isHovered = $0 }
    }

    private func header(onOpenRun: (() -> Void)?) -> ToolRowHeader {
        ToolRowHeader(
            presentation: presentation,
            home: home,
            isError: isError,
            refusal: refusal,
            refusalReason: refusalReason,
            durationMS: durationMS,
            subagentActions: subagentActions,
            runUnavailable: runUnavailable,
            onOpenRun: onOpenRun,
            onToggle: onOpenRun == nil ? nil : onToggle,
            isExpanded: isExpanded,
            isHovered: isHovered
        )
    }
}
