import SwiftUI
import QuartzCore
import BloomCore

/// The sidebar's running mark, at the size it is read at and enlarged enough to see the mechanism.
///
/// It exists because `ImageRenderer` cannot photograph this mark while it is moving. The moving
/// figure is layer backed, and an offscreen render paints SwiftUI's yellow placeholder over any
/// `NSViewRepresentable`, so the only picture `--snapshot` can take of a mark mid pulse is one with
/// a yellow square where the mark should be. This page is captured in a real window instead. See
/// `Snapshot`.
///
/// Photograph it with `Bloom --snapshot-gallery <dir> --gallery running-glyph --running`. The
/// `--running` flag is what starts the heartbeat, since nothing is actually working in a capture.
///
/// The page is in `--snapshot`'s offscreen list as well, and that picture is not a placeholder: a
/// mark with the heartbeat stopped is a plain SwiftUI circle, which is exactly what Reduce Motion
/// draws. It is the picture to take when the alternative would be putting a window in front of
/// whatever the owner is reading.
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

            // The dot is a filled circle in the accent, and so is the unread mark, which makes
            // this the one page where that can be looked at. The column's rule is that its states
            // differ in shape before they differ in colour, and these two now differ in size, in
            // whether they move, and in nothing else. Drawn side by side so the question is asked
            // by the picture rather than left to be discovered in a sidebar.
            VStack(alignment: .leading, spacing: 8) {
                Text("Against the other accent marks")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                HStack(alignment: .top, spacing: 24) {
                    named("Running") { WorkspaceRunningGlyph() }
                    named("Unread") { WorkspaceStatusGlyph(status: .unread) }
                    named("Pull request") { WorkspaceStatusGlyph(status: .pullRequestOpen) }
                }
            }

            // What the sidebar drew INSTEAD, on the day this page was next opened.
            //
            // A workspace whose agent was mid turn showed `circle.dotted`, the mark for a worktree
            // that matches its base branch, because `WorkspaceStatus.resolve` was handed
            // `isRunning: false` and fell through every test to `.clean`. The report called it "a
            // hollow dashed ring" and an hour went into working out which mark that was, so the
            // two are drawn side by side: what the mark meant to say, and what it said. The state
            // that produced it is `AgentTurns` in the core.
            //
            // `.settingUp` is deliberately NOT here, and not because it was ruled out by reading.
            // It is the column's other ring and the obvious third column for this row, and it is a
            // `ProgressView`, which is a representable: drawn into this page it photographs as
            // SwiftUI's yellow placeholder in `--snapshot`'s offscreen pass, which is the one pass
            // an agent can run without putting a window in front of the owner. A page that comes
            // out as a warning sign says less than a page without the column.
            VStack(alignment: .leading, spacing: 8) {
                Text("The mark it was mistaken for")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                HStack(alignment: .top, spacing: 24) {
                    named("Running") { WorkspaceRunningGlyph() }
                    named("No changes") { WorkspaceStatusGlyph(status: .clean) }
                }
            }

            // The same pair on the selection fill, because that is where the report saw them and
            // because every meaning colour in the palette is unreadable there: on a selected row
            // the shape is the whole of what a mark says. See `WorkspaceStatusGlyph.isOnSelection`.
            VStack(alignment: .leading, spacing: 8) {
                Text("The same pair, selected")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                HStack(alignment: .top, spacing: 24) {
                    named("Running") { WorkspaceRunningGlyph(isOnSelection: true) }
                    named("No changes") {
                        WorkspaceStatusGlyph(status: .clean, isOnSelection: true)
                    }
                }
                .padding(8)
                .background(Palette.accentFill)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

    /// One mark at true size with its name under it, and the mark scaled up beside the name so the
    /// two can be told apart on a page rather than only in a column.
    private func named<Mark: View>(_ title: String, @ViewBuilder mark: () -> Mark) -> some View {
        VStack(spacing: 6) {
            mark()
                .frame(width: Metrics.glyph, height: Metrics.glyph)
            mark()
                .frame(width: Metrics.glyph, height: Metrics.glyph)
                .scaleEffect(4, anchor: .center)
                .frame(width: Metrics.glyph * 4, height: Metrics.glyph * 4)
            Text(title)
                .font(Typo.micro)
                .foregroundStyle(Palette.textSecondary)
        }
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

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    ///
    /// It moves and still does not need the keys: the heartbeat has no frontmost gate, so it runs in
    /// a window nobody has given the keyboard to.
    static let runningGlyph = Gallery(
        name: "running-glyph",
        title: "Running mark",
        // Taller than it was, for the two rows that name what this mark was mistaken for. A page
        // that clips is a page whose last section nobody knows is there.
        size: CGSize(width: 700, height: 1240),
        needsFocus: false,
        view: { _ in AnyView(RunningGlyphGallery()) }
    )
}
