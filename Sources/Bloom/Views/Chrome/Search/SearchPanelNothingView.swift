import SwiftUI
import BloomCore

/// What the card draws where its rows would be, when it has none.
///
/// **`EmptyStateView`, which is the app's own answer to this and is `ContentUnavailableView`
/// underneath.** It was worth checking before inventing one: `EmptyTranscriptView` is the nearest
/// neighbour, it uses this type, and its comment says the thing worth keeping here too, that an
/// empty state is a normal state rather than a problem to be announced. Bloom is quiet. So this is
/// a glyph, a short title and one sentence, in the system's own spacing and type, which is also
/// what makes it correct in both appearances and under Reduce Transparency without a second set of
/// colours to keep in step with the card's glass.
///
/// **It fills the height the list would have had.** The card's list is a fixed height now, so
/// nothing here changes the size of the panel: typing the character that turns twelve results into
/// none moves no edge of the card, which is the same complaint the chips answered by reserving
/// their widths.
///
/// The three states say three different things because they are three different facts, and
/// `SearchPanelNothing` is where the words are. The only thing added here is the index notice,
/// which hangs under the message rather than replacing it: a search that missed while the backfill
/// is still running is a fact plus a caveat, not a different answer.
struct SearchPanelNothingView: View {
    var nothing: SearchPanelNothing
    var isIndexing: Bool

    var body: some View {
        EmptyStateView(glyph: glyph, title: nothing.title, message: nothing.message)
            .overlay(alignment: .bottom) { notice }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
    }

    /// The magnifying glass for the two that are about a query, because it is the same mark the
    /// field carries and the eye has just come off it. A fresh install has not searched for
    /// anything, so it gets the mark of the thing it has none of.
    private var glyph: String {
        switch nothing {
        case .nothingYet: "square.stack.3d.up.slash"
        case .noMatch, .noLiveMatch, .noCommand: "magnifyingglass"
        }
    }

    @ViewBuilder
    private var notice: some View {
        if let sentence = nothing.indexNotice(isIndexing: isIndexing) {
            Label(sentence, systemImage: "clock")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, Metrics.pane)
                .padding(.bottom, Metrics.gutter)
        }
    }
}
