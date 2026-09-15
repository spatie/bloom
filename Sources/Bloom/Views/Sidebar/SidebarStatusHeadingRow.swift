import SwiftUI
import BloomCore

/// One section heading in the status view: what the rows under it want, and how many there are.
///
/// It is a row of the list rather than a `Section` header, for the reason the project headers are:
/// the pane is one flat run so that a single `ForEach` can carry the selection, the animations and
/// (in the other shape) the drag. See `SidebarView`.
///
/// Set in the pane's smallest heading rather than at reading size, because these are labels over
/// the work rather than things you act on. Needs you is the one that takes a colour, and it takes
/// the same amber the mark on its rows takes, so the section and its rows say one thing once.
struct SidebarStatusHeadingRow: View {
    var group: SidebarStatusGroup
    var count: Int
    var isFolded: Bool
    /// Nil on a section that cannot be folded, which is every section but Idle.
    var onToggleFold: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Metrics.spacingSmall) {
            Text(group.title.uppercased())
                .font(Typo.micro)
                .tracking(Typo.microTracking)
                .foregroundStyle(group == .needsYou ? Palette.warning : Palette.textTertiary)

            Text(count.formatted(Figures.count))
                .font(Typo.micro)
                .monospacedDigit()
                .foregroundStyle(Palette.textTertiary)

            Spacer(minLength: Metrics.spacingSmall)

            if onToggleFold != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: SidebarMetrics.caretSize, weight: .medium))
                    .foregroundStyle(Palette.textTertiary)
                    .rotationEffect(.degrees(isFolded ? 0 : 90))
                    // At rest a fold nobody is using is furniture, so it is drawn only under the
                    // pointer or while it is holding something away. The same rule the project
                    // header's gear follows.
                    .opacity(isHovered || isFolded ? 1 : 0)
            }
        }
        .padding(.leading, SidebarMetrics.rowIndent)
        .padding(.trailing, Metrics.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHoverChange { isHovered = $0 }
        .onTapGesture { onToggleFold?() }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(count == 1 ? "\(group.title), 1 workspace" : "\(group.title), \(count) workspaces")
        .accessibilityValue(onToggleFold == nil ? "" : isFolded ? "Collapsed" : "Expanded")
    }
}
