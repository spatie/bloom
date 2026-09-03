import SwiftUI
import BloomCore

/// The strip under a browser pane's toolbar saying what the page has handed over.
///
/// **A file that lands in silence is a poor answer**, and it is the half of "no save panel" that
/// has to be paid for: if the reader is not asked where a download goes, the pane has to say where
/// it went. So this appears the moment a download starts, names the file, counts it in, and offers
/// Show in Finder when it is there.
///
/// **Under the toolbar rather than over the page**, so it never covers what the reader was looking
/// at, and it pushes the page down by one row rather than floating: a browser pane is already one
/// pane of a split column and a floating panel inside one is a second window nobody asked for.
///
/// It goes away when the reader closes it, and only then. A strip that removed itself on a timer
/// would be a strip that told somebody about a file after they had looked away, which is the same
/// silence with extra steps.
struct BrowserDownloadsBar: View {
    var downloads: [BrowserDownloadItem]
    var clear: @MainActor () -> Void

    /// The most recent few. A page that has handed over twenty files has said everything it has to
    /// say with the last three, and the rest are in the folder the strip names.
    private static let shown = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(downloads.suffix(Self.shown)) { download in
                row(download)
            }
        }
        .background(Palette.surfaceSunken)
        // Ruled along the bottom, which is what the find bar above it does. Ruled at the top, the
        // two strips drew a rule each when both were showing: two points of line between them,
        // against a `Metrics.hairline` that is deliberately one. The toolbar draws its own rule
        // above whichever strip comes first, so nothing is lost when this one stands alone.
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func row(_ download: BrowserDownloadItem) -> some View {
        HStack(spacing: Metrics.spacingWide) {
            Image(systemName: glyph(download))
                // Sized to the two lines it stands beside, which are 11 and 10 points. At the
                // default it was the largest thing in a row of the quietest type in the app.
                .imageScale(.small)
                .foregroundStyle(tint(download))
                .frame(width: Metrics.glyph)

            VStack(alignment: .leading, spacing: 0) {
                Text(download.name.isEmpty ? "Starting" : download.name)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(download.status)
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }

            if let fraction = download.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
            }

            Spacer(minLength: 0)

            if download.state == .finished, let destination = download.destination {
                Button("Show in Finder") { Reveal.inFinder(destination.path) }
                    .buttonStyle(.accessoryBar)
                    .font(Typo.micro)
            }

            // One button for the whole strip rather than one per row: what it closes is the
            // report, and a row that could be dismissed on its own would invite reading it as
            // cancelling the download.
            Button {
                clear()
            } label: {
                Label("Close", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Palette.textSecondary)
            }
            .buttonStyle(.accessoryBar)
            .help("Stop showing what this page has downloaded")
        }
        .padding(.horizontal, Metrics.spacingWide)
        .frame(height: Metrics.barHeight)
    }

    private func glyph(_ download: BrowserDownloadItem) -> String {
        switch download.state {
        case .running: "arrow.down.circle"
        case .finished: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func tint(_ download: BrowserDownloadItem) -> Color {
        switch download.state {
        case .running: Palette.textSecondary
        case .finished: Palette.positive
        case .failed: Palette.negative
        }
    }
}
