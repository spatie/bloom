import BloomCore
import SwiftUI

/// Which rows in a list have only just turned up, so the list can fade them in rather than
/// popping them onto the screen at full opacity in a single frame.
///
/// ## Why this can never be "the list changed"
///
/// `AppModel.workspaces` is reassigned wholesale every six seconds by the background diff stat
/// refresh, it is reassigned again by every reload, and both lists that draw it rebuild their
/// rows from scratch whenever a filter moves. A fade keyed to any of that would fade the whole
/// list several times a minute, on every launch and every time a filter is touched, which is a
/// great deal worse than the pop it was meant to fix.
///
/// So the question is never "did the list change". It is "which workspace ids are in it that were
/// not in it a moment ago", which is a set difference over stable identity, and which is blind to
/// everything else by construction. A refresh that rewrites every row's diff stat answers with
/// the same set of ids and therefore produces no arrivals at all. So does a row moving between
/// Home's date headings at midnight, a rename, a pin, and an agent starting or finishing.
///
/// ## The three rules
///
/// **Nothing arrives into a list that has never had anything in it.** The first non-empty set of
/// ids is adopted in silence. That is the launch fill, where both lists start empty and are
/// filled from the store a moment later, and it is also Home coming back: `HomeView` is thrown
/// away and rebuilt every time the selection leaves Home, so its tracker starts over and its
/// first fill has to be as quiet as the very first one was. Nothing outside this type has to know
/// when the app finished loading, which is just as well: `AppModel` publishes `workspaces` and
/// `isLoaded` in the same update, so a view cannot tell the launch fill from any other by asking.
///
/// **A change of scope is adopted in silence too.** Widening a filter is the user rearranging
/// what they are looking at, not work arriving, and forty rows fading up at once reads as an
/// effect rather than as a settle. Both lists call `adopt` from the same place they rebuild their
/// rows for a filter change, so the sidebar's Unread and With changes behave exactly as Home's
/// search, project menu and Hide archived do.
///
/// **Everything else that is new, arrives.** A workspace somebody just created, a row put back by
/// an undone archive, and a row a content filter has started letting through because the agent
/// finished its turn while Unread was on. All three are a row genuinely turning up in front of
/// the user, and all three read better as a settle than as a pop.
///
/// Forgetting is symmetric and deliberate: an id that leaves the list is dropped from `known`,
/// which is the whole reason a row that comes back counts as an arrival the second time.
struct RowArrival<ID: Hashable>: Equatable {
    /// The ids that count as having just turned up. A row reads its own id out of this as it is
    /// built, and that is the only moment the answer matters: see `ArrivingRow`.
    private(set) var arriving: Set<ID> = []

    /// The list as it stood the last time it was looked at.
    private var known: Set<ID> = []

    /// Whether this tracker has ever seen a row at all. Until it has, nothing can arrive.
    private var hasFilled = false

    /// Takes in the list as it now stands, and works out what is new about it.
    mutating func absorb(_ ids: some Sequence<ID>) {
        let current = Set(ids)
        defer { known = current }

        guard hasFilled else {
            hasFilled = !current.isEmpty
            arriving = []
            return
        }

        // Narrowed to what is still on screen before anything is added, so a row that arrived and
        // left again before it could fade cannot sit in the set holding the settle open.
        arriving.formIntersection(current)
        // Unioned rather than assigned, so a second arrival landing mid fade joins the first one
        // instead of cutting it off. Both then fade together, which is also the answer to
        // staggering: rows that turn up in the same breath belong to one event and should not
        // arrive in a ripple.
        arriving.formUnion(current.subtracting(known))
    }

    /// Takes the list in with nothing arriving out of it.
    ///
    /// What a filter change calls. See the second rule above.
    mutating func adopt(_ ids: some Sequence<ID>) {
        known = Set(ids)
        hasFilled = hasFilled || !known.isEmpty
        arriving = []
    }

    /// Closes the window during which these rows count as having just turned up.
    ///
    /// Not what starts or ends a fade. Every row that was going to fade has already read this and
    /// latched by the time it runs. See `ArrivalSettle`.
    mutating func settle() {
        arriving = []
    }

    func isArriving(_ id: ID) -> Bool {
        arriving.contains(id)
    }

    /// Whether this id was absent from the list the last time the tracker was shown it.
    ///
    /// **What a row asks when it is built in the same pass that made it exist.** `arriving` is an
    /// answer the tracker can only give once it has been shown the new list, and whatever shows it
    /// runs after the pass that drew the row: a `List` gets away with that because the table builds
    /// its cell later, and a `LazyVStack` does not, because the row is realised in the pass that
    /// created it. Filmed against a real turn, twenty-three rows of a transcript were built and
    /// every one of them read `arriving` as empty. One row faded in that turn, and it was the only
    /// one not asking this question.
    ///
    /// So this asks the other way round: not "have you been told this is new", which needs the
    /// tracker to have been told, but "is this absent from what you were last told", which does
    /// not. It stops being true the moment `absorb` takes the new list in, a fraction of a frame
    /// later, so a row realised at any point after that latches at full opacity. That is the same
    /// rule `isArriving` gives, arrived at without needing to be first.
    ///
    /// The three rules above still hold, because both answers read the same bookkeeping: nothing
    /// is new to a tracker that has never been filled, and `adopt` replaces `known` wholesale, so
    /// a session's history and a widened filter are as silent here as they are there.
    func isNew(_ id: ID) -> Bool {
        hasFilled && !known.contains(id)
    }
}

// MARK: - Drawing it

extension View {
    /// Fades this row's contents in, if it is a row that has only just turned up.
    ///
    /// Goes on the row's own drawing rather than around everything the list wraps it in: the
    /// selection, the separators and the row's own frame all belong to the table.
    func arrivingRow(_ isArriving: Bool) -> some View {
        modifier(ArrivingRow(isArriving: isArriving))
    }

    /// Lets the tracker stop calling its newest rows new. Goes on the `List`.
    func settlesArrivals<ID: Hashable>(_ arrival: Binding<RowArrival<ID>>) -> some View {
        modifier(ArrivalSettle(arrival: arrival))
    }
}

/// The fade itself: an opacity inside the row, started by the row, and nothing whatsoever handed
/// to the list.
///
/// ## What a `List` will and will not honour, measured rather than assumed
///
/// A `List` on macOS is an `NSTableView` and it owns its own insertions. Three things were tried
/// on the real app against a real insertion, captured off the window at 60 frames a second:
///
/// 1. `.transition(.opacity)` on the row. Never read. `SidebarView` already records this from
///    the other direction, along with an `.animation` on a `Section`, which a section cannot
///    carry because a section is a layout instruction rather than a view.
/// 2. `.opacity(isArriving ? 0 : 1)` with `.animation(_:value: isArriving)`, driven by a flag the
///    list's own view owns and clears a moment later. Also never read, and this is the one worth
///    recording, because it looks like it must work and the logs say it nearly does. The row's
///    body really is evaluated once at zero and again at one, thirty milliseconds apart. What
///    does not happen in between is a frame: the table has not built the cell yet, so the value
///    has already finished changing by the time anything of this row exists on screen, and there
///    is nothing for the curve to travel. Stretched to a second and a half to be certain, the row
///    still appeared in a single frame.
/// 3. This. The row's own `@State`, latched from its own `onAppear`. Whenever the table gets
///    round to building the cell, the fade starts from that cell's first frame, because the
///    animation is started by the cell rather than aimed at it.
///
/// So the insertion is not animated and cannot be. The row is inserted at full height in one
/// frame exactly as it always was, and what fades is what is drawn inside it. Nothing moves,
/// nothing reflows, and the table never learns that anything happened.
///
/// The one thing this cannot reach is a selection. Under `.listStyle(.sidebar)` the highlight is
/// drawn by the table behind the view, so a workspace that is selected the moment it is created
/// gets its plate at once and its name a beat later. At this length that reads as the name
/// settling into the row, which is the intention, and the alternative is giving up the system's
/// source list selection to own the drawing of it.
private struct ArrivingRow: ViewModifier {
    let isArriving: Bool

    /// Read here rather than at the four call sites, which is a departure from the rest of the
    /// app and is the point of putting this in one place: this is a whole mechanism rather than a
    /// constant a caller picks up or drops. `TranscriptMotion.arrival` answers with the settle or
    /// with nothing, so there is no way to keep half of it.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether this row has done its arriving. Latched, and never unlatched: a row fades in once
    /// in its life, and if it leaves the list and comes back it is a new view with new state.
    @State private var hasLanded = false

    /// The settle this row is owed, or nothing: a row that was already here, or a reader who has
    /// asked for less movement.
    private var settle: TranscriptMotion.Arrival? {
        isArriving ? TranscriptMotion.arrival(reduceMotion: reduceMotion) : nil
    }

    func body(content: Content) -> some View {
        let owed = settle
        content
            .opacity(hasLanded || owed == nil ? 1 : 0)
            // `offset` rather than `padding` or a `frame`, and that is the whole reason a rise is
            // affordable here: it is applied when the row is drawn and not when it is laid out, so
            // the row still occupies exactly the height it always did, nothing under it moves, and
            // the scroll view's own idea of where the end of the content is never changes. A row
            // that grew into place would fight the anchor that keeps a running turn at the live
            // end; this cannot.
            .offset(y: hasLanded || owed == nil ? 0 : (owed?.rise ?? 0))
            // The cell exists by the time this runs, which is the whole difference between this
            // working and the two approaches above it that do not.
            //
            // It also settles the case of a row built long after it arrived, which is a row that
            // was off the bottom of a long list when it turned up and is only now being scrolled
            // to. `isArriving` has expired by then, so it latches at full opacity and no fade is
            // played for something the user was never looking at.
            .onAppear {
                // Dropped rather than slowed under Reduce Motion, matching every other call site
                // in the app: the setting is about movement, not about speed, and there is no
                // slower version of this worth having.
                guard let owed else {
                    hasLanded = true
                    return
                }
                // One animation, two attributes. `easeOut` is what makes the short length carry:
                // it puts most of both the opacity and the travel in the first third and spends
                // the rest arriving.
                withAnimation(.easeOut(duration: owed.seconds)) { hasLanded = true }
            }
    }
}

/// Closes the window during which a row counts as having just arrived.
///
/// The fade itself does not wait for this: `ArrivingRow` latches on its own `onAppear`, and by
/// then the row is on screen and the tracker's answer no longer matters to it. What this bounds
/// is how long the answer stays yes, so that a row scrolled out of a long list and back months
/// later is not greeted as a new arrival.
///
/// Two hundred milliseconds, which is a margin rather than a measurement. The table built the
/// cell 38 milliseconds after the row was absorbed on the machine this was written on, and the
/// only cost of being generous is that a row that took longer than expected to be drawn still
/// gets its fade.
private struct ArrivalSettle<ID: Hashable>: ViewModifier {
    @Binding var arrival: RowArrival<ID>

    func body(content: Content) -> some View {
        content.task(id: arrival.arriving) {
            guard !arrival.arriving.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            arrival.settle()
        }
    }
}
