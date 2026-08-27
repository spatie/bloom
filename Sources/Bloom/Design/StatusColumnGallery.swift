import SwiftUI
import BloomCore

/// The whole status column in one picture, at the size it is read at and enlarged enough to see
/// the strokes.
///
/// It exists because of a report that could not be answered any other way: "that arrow icon in the
/// list is very thin compared to the rest". The marks are decided one `case` at a time in
/// `WorkspaceStatusGlyph`, so nothing in the source shows the thing being complained about, which
/// is how a dozen of them look **beside each other** down 260 points. The legend is that picture in
/// the running app, and looking at the running app means putting a window in front of whoever is
/// using this Mac. This page is the same picture offscreen.
///
/// `--snapshot` writes it as `status-column-<appearance>.png`, and `--snapshot-gallery <dir>
/// --gallery status-column` draws it in a window if a real one is ever wanted.
///
/// **`settingUp` and `running` are not on it, and neither is an oversight.** The first is a
/// `ProgressView` and the second is layer backed, so `ImageRenderer` paints SwiftUI's yellow
/// placeholder over both and a page that comes out as two warning signs says less than a page
/// without the two columns. `RunningGlyphGallery` is where the running mark is photographed, and
/// its own note explains the mechanism at length.
struct StatusColumnGallery: View {
    /// Every state that survives an offscreen render, in `WorkspaceStatus`'s own order, so the
    /// page cannot fall behind the enum: a state added there appears here without this file being
    /// touched.
    private static let states = WorkspaceStatus.allCases.filter {
        $0 != .settingUp && $0 != .running
    }

    /// The three marks the report was about. SF Symbols ships no filled form of any of them, which
    /// is why the answer was a weight rather than a swap, and why they are worth enlarging beside
    /// a filled neighbour rather than left to be judged at eleven points.
    private static let strokes: [WorkspaceStatus] = [
        .pullRequestOpen, .merged, .changed, .checksFailing,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Status column")
                .font(Typo.title)

            column("On the sidebar's own ground", onSelection: false, background: Palette.surface)
            column("On a selected row", onSelection: true, background: Palette.accentFill)

            VStack(alignment: .leading, spacing: 8) {
                Text("The three stroked marks, and a filled one to judge them against")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                HStack(alignment: .top, spacing: 32) {
                    ForEach(Self.strokes, id: \.self) { enlarged($0) }
                }
            }
        }
        .padding(Metrics.gutter)
        .background(Palette.surface)
    }

    private func column(_ title: String, onSelection: Bool, background: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.states, id: \.self) { status in
                    HStack(spacing: Metrics.spacingWide) {
                        WorkspaceStatusGlyph(status: status, isOnSelection: onSelection)
                        Text(status.label)
                            .font(Typo.caption)
                            .foregroundStyle(
                                onSelection ? Palette.textInverted : Palette.textPrimary
                            )
                    }
                }
            }
            .padding(10)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func enlarged(_ status: WorkspaceStatus) -> some View {
        VStack(spacing: 8) {
            WorkspaceStatusGlyph(status: status)
                .scaleEffect(6, anchor: .center)
                .frame(width: Metrics.glyph * 6, height: Metrics.glyph * 6)
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(status.label)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
        }
    }
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    ///
    /// Nothing on it moves and nothing on it is typed into, so it asks for neither the heartbeat
    /// nor the keys.
    static let statusColumn = Gallery(
        name: "status-column",
        title: "Status column",
        size: CGSize(width: 640, height: 900),
        needsFocus: false,
        view: { _ in AnyView(StatusColumnGallery()) }
    )
}
