import SwiftUI
import BatonCore

/// One tool call: a line that says what happened, and everything behind it when opened.
struct ToolRowView: View {
    var use: AgentToolUse
    var result: AgentToolResult?
    var isError: Bool
    var durationMS: Int?
    var isExpanded: Bool
    var onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExpandableRowHeader(isExpanded: isExpanded, onToggle: onToggle) {
                ToolRowHeader(
                    presentation: ToolPresenter.present(use),
                    isError: isError,
                    durationMS: durationMS,
                    isExpanded: isExpanded,
                    isHovered: isHovered
                )
            }

            if isExpanded {
                ToolDetailView(use: use, result: result)
                    .padding(.leading, TranscriptLayout.detailIndent)
                    .padding(.trailing, TranscriptLayout.inset)
                    .padding(.bottom, TranscriptLayout.tight * 2)
            }
        }
        .modifier(ExpandableRow(isHovered: isHovered, isError: isError))
        .onHover { isHovered = $0 }
    }
}
