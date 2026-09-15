import SwiftUI

/// One notice across the top of the centre column: a glyph, a sentence, what it is about, and the
/// buttons that answer it.
///
/// The register is `TerminalRestartStrip` grown to more than one line: the same surface, the same
/// hairline under it, the same small controls, so a notice about the workspace reads as the same
/// kind of thing as a notice about a pane.
struct WorkspaceNoticeStrip<Detail: View, Actions: View>: View {
    var symbol: String
    var tint: Color
    var title: String
    var onDismiss: (() -> Void)?
    @ViewBuilder var detail: Detail
    @ViewBuilder var actions: Actions

    init(
        symbol: String, tint: Color, title: String, onDismiss: (() -> Void)? = nil,
        @ViewBuilder detail: () -> Detail, @ViewBuilder actions: () -> Actions
    ) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.onDismiss = onDismiss
        self.detail = detail()
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.spacingWide) {
            Image(systemName: symbol)
                .font(Typo.label)
                .foregroundStyle(tint)
                .padding(.top, Metrics.spacingHair)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text(title)
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Metrics.spacing) {
                actions
                if let onDismiss {
                    Button("Dismiss", systemImage: "xmark", action: onDismiss)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .help("Dismiss")
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.spacingWide)
        .frame(maxWidth: .infinity)
        .background(Palette.surface)
        .overlay(alignment: .bottom) { Hairline() }
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
