import SwiftUI
import BloomCore

/// The line along the foot of Home's list, saying what is in it.
///
/// **It used to be the trailing end of the strip at the top, and the owner's word for it was
/// "strange".** Two things were wrong with it up there. The bar was doing three jobs in one line,
/// so five chips, a project picker and a sentence all read at one weight and nothing led. And a
/// count printed above the thing it counts is a count in the wrong place: Finder says "23 items,
/// 140 GB available" along the bottom of the window, Mail counts its messages there, and both of
/// them are next to what they are counting.
///
/// Finder's register, deliberately: one line, caption ink, centred, a rule above it, and nothing
/// on it to press. The project filter stayed up on the strip for that last reason.
///
/// **There is one thing on it to press now, and the rule it bends is worth stating rather than
/// quietly breaking.** The argument that kept the project filter up on the strip was about a
/// control that changes what the list shows: such a control belongs beside the other controls
/// that do, above the rows. Compacting the database changes nothing about the list. It acts on
/// the number printed an inch to its left, it is offered only in the rare state where that number
/// is worth acting on, and the alternative arrangement is what this whole change removed: the
/// size of the database in one window and the only way to reclaim it in another.
///
/// **It sits beside `SidebarStatusBar`, and the two are meant to read as one band.** They are both
/// `Palette.sidebar` at `Metrics.barHeight` with a `Hairline` over them, so what divides them
/// across the bottom of the window is the split view's own rule and nothing else. The sidebar's
/// half was on `.bar`, a material, which put it a few units off the column it stands in and off
/// this; that is the same argument `HomeBar` makes about the glass it lost.
struct HomeStatusBar: View {
    /// What the list adds up to, worked out by `HomeList.summary`. Empty means there is nothing to
    /// say, and then the bar is not drawn at all.
    var summary: String
    /// The offer to hand the database's free pages back to the disk, or nil, which is nearly
    /// always. One value rather than three parameters, so the offer and the words that explain it
    /// cannot be drawn half present.
    var compaction: Compaction?

    /// Everything the button needs, from the one caller that has it.
    struct Compaction {
        /// `DatabaseSize.compactionHelp`: the paragraph a one-line bar has no room for.
        var help: String
        var isRunning: Bool
        var run: () -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            Hairline()

            HStack(spacing: Metrics.spacing) {
                Text(summary)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Centred in what is left rather than in the pane, so a long line and the
                    // button cannot end up drawn over one another on a narrow window. The offer
                    // is up on a handful of days in the life of an install; the line is up every
                    // day, and it is the line that must never be unreadable.
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Showing \(summary)")

                if let compaction { button(compaction) }
            }
            .padding(.horizontal, HomeMetrics.gutter)
            .frame(height: Metrics.barHeight)
        }
        .background(Palette.sidebar)
        // The bar is no longer merged into one element. It was, back when it held nothing but a
        // sentence, and a merged element has nowhere to put a button: the compaction offer would
        // have been read out as part of the sentence and reachable by nothing. The label above is
        // where the merged one went.
    }

    private func button(_ compaction: Compaction) -> some View {
        Button(compaction.isRunning ? "Compacting" : "Compact", action: compaction.run)
            .controlSize(.small)
            .disabled(compaction.isRunning)
            .help(compaction.help)
    }
}
