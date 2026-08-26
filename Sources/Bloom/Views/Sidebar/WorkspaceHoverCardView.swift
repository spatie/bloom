import SwiftUI
import BloomCore

/// The card that opens beside a workspace row while the pointer rests on it.
///
/// What it says is `WorkspaceHoverCard`'s, in the core, where the suite holds it. This is the
/// drawing and nothing else, which is why it takes one value rather than a workspace and a pull
/// request: a card assembled here would be a card assembled in a target the tests cannot import.
///
/// **It takes no clicks, and that is the design rather than a limitation of it.** The panel it is
/// drawn in ignores the mouse entirely (see `WorkspaceHoverCardPresenter`), so nothing here is a
/// button, the pull request number is a fact rather than a link, and the pointer never has to
/// travel off the row and across a gap to reach anything. `AttachmentCard` over the composer made
/// the same call for the same reason, and it is the reason the sidebar row keeps its own hover
/// controls: what you can DO to a workspace is on the row, under the pointer already, and what is
/// TRUE of it is here.
///
/// Four lines, in the order the question is asked. The branch and its counts, because that is
/// what the pane has no room for at all; the name in full, because the pane truncates it; the
/// state in words beside the pull request, because the mark alone cannot say "1 of 12 checks
/// failed"; and the age, which is what says whether any of the rest is still true.
struct WorkspaceHoverCardView: View {
    var card: WorkspaceHoverCard

    /// Wider than the 260 point sidebar, deliberately. The whole point of the card is having room
    /// the row does not, and a card the width of the pane it opens out of reads as the pane
    /// repeated rather than as the pane explained. Wide enough for a two line workspace name at
    /// reading size, which is what most of them come to.
    static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            branchLine
            title
            footer
        }
        .padding(Metrics.gutter)
        .frame(width: Self.width, alignment: .leading)
        // Sized by its content, so a one line name draws a shorter card than a three line one.
        // The panel asks the hosting view for this height. See the presenter.
        .fixedSize(horizontal: false, vertical: true)
        .background(cardBackground)
        // The card is drawn in a window of its own, which cannot be reached by the pointer or by
        // VoiceOver. Everything on it is on the row as well, in the row's own accessibility value
        // and its tooltip, so there is nothing here for a screen reader to lose. See the
        // presenter for what a keyboard user gets instead.
        .accessibilityHidden(true)
    }

    // MARK: - Lines

    /// The branch, with the counts hard against the card's trailing edge.
    ///
    /// The branch truncates from the HEAD rather than the tail. Bloom's branch names are prefixed
    /// (`freek/`, `agent/2026-08/`) and the distinguishing half is the last component, so cutting
    /// the front is what keeps two workspaces on the same prefix tellable apart. It is the same
    /// call `AttachmentCard` makes about a path.
    private var branchLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing) {
            Text(card.branch)
                .font(Typo.codeSmall)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: Metrics.spacingSmall)

            // Nothing at all when there is nothing to count, rather than the words "No changes".
            // Photographed both ways: the state line two rows down is `WorkspaceStatus.clean`,
            // whose label is those same two words, so the card said "No changes" twice in a
            // hundred points of each other and read as a stutter rather than as an empty
            // worktree. The state line is the one that keeps it, because it is where every other
            // card puts its verdict.
            if let diff = card.diff {
                // The window's one diff stat, not a second one. It abbreviates past a thousand,
                // which is what every other pair of counts in the app does, so a card and the row
                // it opened out of cannot report the same worktree two different ways.
                DiffStatLabel(additions: diff.additions, deletions: diff.deletions)
            }
        }
    }

    /// The name, whole, and the mark that the row draws beside it.
    ///
    /// The mark is at the trailing edge of this line rather than in the corner above it, which is
    /// where Conductor puts it. Measured against the alternative on paper: in the corner it sits
    /// on the branch's line and reads as a fact about the branch, which for `checksFailing` is
    /// nearly true and for `awaitingPermission` is not true at all. Beside the name it belongs to
    /// the workspace, which is what it is about, and it is on the same line as the biggest text on
    /// the card, which is where the eye lands first.
    ///
    /// `WorkspaceStatusGlyph` rather than a glyph of its own, so a state that is a pencil in the
    /// sidebar is a pencil here. Every one of the fourteen shapes and its colour is decided there
    /// and in `WorkspaceStatus`, and the legend draws from the same type.
    private var title: some View {
        HStack(alignment: .top, spacing: Metrics.spacing) {
            Text(card.title)
                .font(Typo.title)
                .foregroundStyle(Palette.textPrimary)
                // Three, not one. The card exists because the row shows one; a name that runs past
                // three lines is one somebody pasted a paragraph into, and the card is not the
                // place to read a paragraph.
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            WorkspaceStatusGlyph(status: card.status)
                // The glyph sizes itself to the sidebar's icon column and is drawn at the cap
                // height of the caption beside it there. Here it stands next to a heading, so it
                // is nudged onto that line's baseline rather than the box's top edge.
                .padding(.top, Metrics.spacingTight)
        }
    }

    /// The state in words with the numbers behind it, and under that the pull request and the age.
    ///
    /// **Two lines rather than one, and the picture is what decided it.** All four were on one
    /// line first, and photographed the failing case read "Checks failing 1 of 12 required checks
    /// f... #362 1d ago": four unrelated facts fighting over 296 points, with the only one that
    /// says WHY the checks failed the one that got cut. The state and its detail are one
    /// sentence, so they keep a line; the number and the age are each a single token and share
    /// the next.
    ///
    /// The pull request is drawn as `#362` in the same monospaced digits `PullRequestBadge` uses
    /// and with none of its chrome: no rim, no arrow, no hover fill. That is deliberate and it is
    /// the honest half of the card taking no clicks. `PullRequestBadge`'s own note says a control
    /// that looks pressable and is not is the kind of thing people learn to distrust a whole strip
    /// over, and a badge with an arrow on it inside a window that ignores the mouse would be
    /// exactly that. The way out to GitHub is the badge itself, one row-click away in the
    /// inspector strip.
    private var footer: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingSmall) {
                Text(card.state)
                    .font(Typo.captionEmphasis)
                    .foregroundStyle(WorkspaceStatusGlyph.tint(for: card.status))
                    .lineLimit(1)
                    .layoutPriority(1)

                if let detail = card.detail {
                    Text(detail)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingSmall) {
                if let pullRequest = card.pullRequest {
                    // `verbatim`, for the reason `PullRequestBadge` writes down: an interpolated
                    // `Int` inside a `LocalizedStringKey` is formatted for the locale, and a
                    // machine set to Dutch drew "#2.631" for a pull request GitHub calls 2631.
                    Text(verbatim: "#\(pullRequest.number)")
                        .font(Typo.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textSecondary)
                }

                Spacer(minLength: Metrics.spacingSmall)

                Text(card.age)
                    .font(Typo.caption)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }

    // MARK: - The plate

    /// The card's own ground.
    ///
    /// `MenuPanel` is the app's floating card and this is deliberately not it. `MenuPanel` samples
    /// the window it is drawn in (glass since macOS 26, `.withinWindow` vibrancy before that) and
    /// carries a SwiftUI shadow, both of which are right inside the composer's window and neither
    /// of which is right here: this card IS a window, so the material has to blend with what is
    /// behind the window rather than with the window, and the shadow is AppKit's to draw around
    /// the panel's alpha. What is kept is the shape and the rim, so the two read as one family.
    private var cardBackground: some View {
        VisualEffectBackground(material: .menu, blending: .behindWindow)
            // Clipped rather than filled through a shape, because the material is a view rather
            // than a `ShapeStyle` and `background(_:in:)` will not take one.
            .clipShape(RoundedRectangle(cornerRadius: Metrics.corner))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.corner)
                    .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
            }
    }
}
