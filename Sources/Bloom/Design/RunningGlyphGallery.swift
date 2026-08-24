import SwiftUI
import QuartzCore
import BloomCore

/// The sidebar's running mark, at the size it is read at and enlarged enough to see the mechanism.
///
/// It exists because `ImageRenderer` cannot photograph this mark. The moving figure is layer backed,
/// and an offscreen render paints SwiftUI's yellow placeholder over any `NSViewRepresentable`, so
/// the only picture `--snapshot` can take of the sidebar is one with a yellow square where the mark
/// should be. This page is captured in a real window instead. See `Snapshot`.
///
/// Photograph it with `Bloom --snapshot-gallery <dir> --gallery running-glyph --running`. The
/// `--running` flag is what starts the heartbeat, since nothing is actually working in a capture.
struct RunningGlyphGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Running mark")
                .font(Typo.title)

            row(
                "In a row, unselected",
                background: Palette.surface,
                onSelection: false
            )
            row(
                "In a row, selected",
                background: Palette.accentFill,
                onSelection: true
            )

            HStack(alignment: .top, spacing: 32) {
                enlarged("Moving", onSelection: false)
                enlarged("Selected", onSelection: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Four rows, one heartbeat")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                ForEach(0..<4, id: \.self) { index in
                    mockRow(name: "workspace \(index + 1)", background: Palette.surface, onSelection: false)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ title: String, background: Color, onSelection: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
            mockRow(name: "Review PR 168", background: background, onSelection: onSelection)
        }
    }

    private func mockRow(name: String, background: Color, onSelection: Bool) -> some View {
        HStack(spacing: 8) {
            WorkspaceRunningGlyph(isOnSelection: onSelection)
                .frame(width: Metrics.glyph, height: Metrics.glyph)
            Text(name)
                .font(Typo.body)
                .foregroundStyle(onSelection ? Palette.textInverted : Palette.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(width: 260, height: 32)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// Eight times, drawn by scaling the real mark rather than by a second implementation, so the
    /// picture cannot disagree with the app about what is on screen.
    private func enlarged(_ title: String, onSelection: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
            WorkspaceRunningGlyph(isOnSelection: onSelection)
                .frame(width: Metrics.glyph, height: Metrics.glyph)
                .scaleEffect(8, anchor: .center)
                .frame(width: Metrics.glyph * 8, height: Metrics.glyph * 8)
                .background(onSelection ? Palette.accentFill : Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
