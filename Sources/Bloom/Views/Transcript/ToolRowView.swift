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
    var workspace: Workspace
    var result: AgentToolResult?
    var isError: Bool
    /// Set when the call never ran. A refusal is drawn as one throughout: not the red a failure
    /// gets, because nothing failed. See `ToolRefusal`.
    var refusal: ToolRefusal?
    /// What the CLI said about the refusal, in one line.
    var refusalReason: String = ""
    var durationMS: Int?
    var isExpanded: Bool
    var onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExpandableRowHeader(isExpanded: isExpanded, onToggle: onToggle) {
                ToolRowHeader(
                    presentation: presentation,
                    workspace: workspace,
                    isError: isError,
                    refusal: refusal,
                    refusalReason: refusalReason,
                    durationMS: durationMS,
                    isExpanded: isExpanded,
                    isHovered: isHovered
                )
            }

            if isExpanded {
                ToolDetailView(use: use, result: result, refusal: refusal, refusalReason: refusalReason)
                    .padding(.leading, TranscriptLayout.detailIndent)
                    .padding(.trailing, TranscriptLayout.inset)
                    .padding(.bottom, TranscriptLayout.block)
            }
        }
        .modifier(ExpandableRow(isHovered: isHovered))
        .onHover { isHovered = $0 }
    }
}
