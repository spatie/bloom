import SwiftUI
import BloomCore

/// One fact about an installation: what it is, what it does and, when it has one, where it lives.
struct ServerSummaryRow: View {
    let row: ServerInstallationSummary.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingWide) {
            Image(systemName: row.symbol)
                .foregroundStyle(Palette.controlAccent)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text(row.title).font(Typo.bodyEmphasis)
                Text(row.detail).font(Typo.label).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let location = row.location {
                    Text(location).font(Typo.codeSmall).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
