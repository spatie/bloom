import SwiftUI
import BloomCore

/// One fact about an installation: what it is, what it does and, when it has one, where it lives.
struct ServerSummaryRow: View {
    let row: ServerInstallationSummary.Row
    /// Off on the setup page, whose rows have to fit beside the optional extras without scrolling;
    /// the paths are all in its "Where everything is" popover. Server Settings has the room and
    /// keeps them.
    var showsLocation = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingWide) {
            Image(systemName: row.symbol)
                .foregroundStyle(Palette.controlAccent)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: showsLocation ? Metrics.spacingSmall : 2) {
                Text(row.title).font(Typo.bodyEmphasis)
                Text(row.detail).font(Typo.label).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if showsLocation, let location = row.location {
                    Text(location).font(Typo.codeSmall).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
