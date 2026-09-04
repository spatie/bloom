import BloomCore
import Foundation
import QuartzCore

/// What a transcript's holds did, for a probe to read. See `TranscriptHoldView`.
///
/// Three questions a report has to answer and an impression cannot. **Did the hold engage at
/// all**, which is what tells a run whose frame times improved that they improved for the reason
/// claimed. **How many rows were measured**, which is the cost both holds exist to remove and the
/// one number to compare two builds on. And **which gestures AppKit calls a live resize**: a window
/// edge does, a SwiftUI `DragGesture` on a pane divider cannot, and whether an `NSSplitView`
/// divider does is a thing to measure on this system rather than to remember from a document.
///
/// Counters, written where the holds are and read by nothing but a report.
///
/// **A counter added here is code on the app's own path, so where it is written matters as much as
/// what it counts.** An increment is free; a walk over the visible rows is not, and this file has
/// already reported a regression that was its own. See the head of `ProbeHarness`. Increment where
/// the thing happens, and take anything that has to LOOK at the screen on the settle.
///
/// **And before adding one at all, run `sample`.** Three counters here were added to find why a
/// transcript scrolled badly and all three acquitted their suspect, because a counter can only
/// find what somebody already suspected. A profiler found it in eight seconds, in a shape none of
/// them was written to notice. The order that works is profile first and count afterwards, to
/// watch what the profile named. The argument is at the head of `ProbeHarness`.
@MainActor
enum TranscriptHoldCensus {
    private(set) static var holds = 0
    private(set) static var underAHand = 0
    private(set) static var underLiveResize = 0
    private(set) static var liveResizes = 0
    /// Panes blanked because they were pointed at another conversation, and panes faded back in.
    /// A count that stays behind is a pane left waiting for rows that never came.
    private(set) static var arrivals = 0
    private(set) static var reveals = 0
    /// **The number that says whether any of this worked.** Every `NSHostingView` built to measure
    /// a row, wherever it was built from. A switch used to build one per row in the window because
    /// the workspace changing counted as the environment changing; a resize used to build one per
    /// row per drag.
    private(set) static var measurements = 0
    /// Rows a reflow left holding an estimate rather than measuring. What the hold buys.
    private(set) static var estimatedRows = 0
    /// **Rows expected to draw something that measured nothing.** See `silenced(_:)`, which
    /// carries why one of these is a row the reader never sees again. `silences` is the log, up to
    /// `mostSilences` of them, and `silencedRows` is the count of all of them.
    private(set) static var silencedRows = 0
    private(set) static var silences: [Silence] = []
    /// **The check that a row is the height it draws at.** Rows that reported the height they
    /// drew at, and how many of those the table was still drawing at another height a turn after
    /// it was told. See `TranscriptTable.Coordinator.checkCorrected`, which carries the bug.
    private(set) static var correctedRows = 0
    private(set) static var uncorrectedRows = 0
    /// **What is on the screen, and how much of it is a guess.** Sampled when the view has stopped
    /// moving: the most rows the reader could see at once that the table was drawing at a height
    /// nobody has measured, and the most it was drawing at a height that disagrees with what was
    /// measured. Either of them above nought is white space the reader can see.
    ///
    /// Sampled on the settle rather than on every frame, because the walk is over the visible rows
    /// and a screenful is not a fixed number of them: see `censusOfTheScreen`.
    private(set) static var screenEstimated = 0
    private(set) static var screenWrong = 0
    private(set) static var screensSeen = 0
    /// The same two on the last screen sampled after the movement stopped, which is what tells a
    /// guess that is being corrected as the reader flies past from one that is simply standing
    /// there. See `TranscriptTable.Coordinator.scheduleSettle`.
    private(set) static var screenEstimatedSettled = 0
    private(set) static var screenWrongSettled = 0
    /// **What a correction costs the table.** Every `noteHeightOfRows` call, the rows in them, and
    /// every time a correction wrote the scroll offset to keep the reader where they were. A
    /// scroll upwards draws rows nobody has drawn before, so all three climb with distance, which
    /// is what "the higher I go the more stuttery it gets" is made of.
    private(set) static var noteCalls = 0
    private(set) static var notedRows = 0
    private(set) static var placeWrites = 0
    /// **How often the list built its entries, and how many it built.** One pass builds an entry
    /// for every row in the window: a content key hashed from a dozen fields, two closures
    /// allocated, and a payload sniffed. So this is the work that is proportional to the ROW COUNT
    /// rather than to what is on screen, and the number that says whether a scroll is paying it.
    ///
    /// Counted per pass rather than per entry, which is the lesson at the head of `ProbeHarness`:
    /// an increment and an add, whatever the window holds.
    ///
    /// **These two were predicted to be the stutter, and they are not. Written down because the
    /// prediction was made in public and failed in public.** The reasoning was that an upward
    /// scroll grows the window about eight times, that each grow costs a pass over every entry in
    /// it, and that a pass of that size costs about fifty milliseconds: sixteen passes, 29,000
    /// entries, 800ms of a three second sweep, 27 per cent of its frames. The run returned 13
    /// passes and 13,410 entries, so the mechanism was real. It also returned a ceiling of 0.8ms
    /// on every SwiftUI layout of the centre pane across a 22 second sweep, 3,512 of them totalling
    /// 481ms, which is two per cent of the wall clock. The fifty milliseconds was invented and
    /// never measured, and 27 per cent predicted against 27 per cent observed would have convinced
    /// both readers of it if the count had not been falsifiable alongside.
    ///
    /// The cost is in the AppKit half, which nothing here timed. See `cellSeconds`.
    private(set) static var entryPasses = 0
    private(set) static var entriesBuilt = 0
    /// **The AppKit half, which nothing measured until the SwiftUI half was proved innocent.**
    ///
    /// `PaneLayoutTiming` times the pane's own SwiftUI pass and says it never exceeds a
    /// millisecond. What it cannot see is everything the table does around it: asking the delegate
    /// for heights, building a row's `NSHostingView`, and relaying out when a height is corrected.
    /// A row scrolled into view costs a whole SwiftUI graph, and none of that happens inside the
    /// pane's layout.
    ///
    /// `cellsAsked` is every call of `viewFor`; `cellsBuilt` is the ones that actually replaced the
    /// root view, because a recycled cell holding the content it already holds returns early. The
    /// seconds are around that replacement.
    ///
    /// **And the seconds do not mean what they were added to mean. Measured: 0.0123 seconds over a
    /// sweep that dropped 29 per cent of its frames, 0.007ms a cell.** Predicted 5 to 12 seconds,
    /// from 2.1ms a cell, which is a figure this file records for `measure(_:at:)`: a hosting view
    /// built, given a width constraint, laid out and asked for its `fittingSize`. Assigning
    /// `rootView` is none of that. It hands SwiftUI a new tree and returns, and the layout it
    /// causes happens later, in the hosting view's own pass, outside this bracket.
    ///
    /// So a small number here does not acquit building a row. It says the cost is not in the
    /// statement this brackets, and a bracket around a statement whose work is deferred cannot say
    /// where it went. The 2.1ms was borrowed from an operation that does the work synchronously
    /// and carried into an argument about one that does not: a number is evidence for the thing it
    /// measured and for nothing else.
    private(set) static var cellsAsked = 0
    private(set) static var cellsBuilt = 0
    private(set) static var cellSeconds = 0.0
    private(set) static var cellWorstMs = 0.0
    /// Every time the table asked the delegate how tall a row is.
    ///
    /// **The one number that says whether a correction is O(the rows below it).** If AppKit re-asks
    /// for every row of the table each time `noteHeightOfRows` names one, then 505 corrections over
    /// a 2,981 row conversation is a million and a half delegate calls, each a hashed dictionary
    /// lookup. If it asks only for what it was told about, this stays in the tens of thousands.
    /// Two answers three orders of magnitude apart, from one increment.
    private(set) static var heightAsks = 0
    /// The time inside `noteHeightOfRows` itself, which is AppKit's relayout of the rows below a
    /// correction.
    private(set) static var noteSeconds = 0.0
    private(set) static var noteWorstMs = 0.0

    static func held(_ what: TranscriptPaneHold.PaneHeld, underAHand hand: Bool, liveResize: Bool) {
        switch what {
        case .whatIsDrawn:
            holds += 1
            if hand { underAHand += 1 }
            if liveResize { underLiveResize += 1 }
        case .nothing:
            arrivals += 1
        }
    }

    static func liveResizeBegan() { liveResizes += 1 }

    static func revealed() { reveals += 1 }

    /// One row measured, from anywhere. See `TranscriptTable.Coordinator.measure`.
    static func measured() { measurements += 1 }

    static func released(estimated: Int) { estimatedRows = estimated }

    /// One screenful, as it was drawn. The worst of them is what is kept.
    static func sawScreen(estimated: Int, wrong: Int, settled: Bool = false) {
        screensSeen += 1
        screenEstimated = max(screenEstimated, estimated)
        screenWrong = max(screenWrong, wrong)
        if settled {
            screenEstimatedSettled = estimated
            screenWrongSettled = wrong
        }
    }

    /// One write of the scroll offset that actually moved it.
    static func placed() { placeWrites += 1 }

    /// One cell handed to the table, and whether its root view had to be replaced. See `cellsBuilt`.
    static func askedCell(rebuilt: Bool, seconds: Double) {
        cellsAsked += 1
        guard rebuilt else { return }
        cellsBuilt += 1
        cellSeconds += seconds
        cellWorstMs = max(cellWorstMs, seconds * 1000)
    }

    /// One height answered. See `heightAsks`: an increment and nothing else, on a path AppKit can
    /// call a million times.
    static func askedHeight() { heightAsks += 1 }

    /// One `noteHeightOfRows`, and what it took. See `noteSeconds`.
    static func noted(rows: Int, seconds: Double) {
        noteCalls += 1
        notedRows += rows
        noteSeconds += seconds
        noteWorstMs = max(noteWorstMs, seconds * 1000)
    }

    /// The clock, but only while a probe is measuring. Two reads of it per cell is nothing; the
    /// point of the gate is that a shipping build takes neither.
    static func clock() -> Double {
        PaneLayoutTiming.isEnabled ? CACurrentMediaTime() : 0
    }

    static func since(_ started: Double) -> Double {
        started > 0 ? CACurrentMediaTime() - started : 0
    }

    /// One pass over the list's entries. See `entryPasses`.
    static func builtEntries(_ count: Int) {
        entryPasses += 1
        entriesBuilt += count
    }

    /// **A row that was expected to draw something turned out to measure nothing.**
    ///
    /// The blank transcript a composer drag leaves, watched rather than reasoned about. A height
    /// of nought is remembered as an answer: `TranscriptRowHeights.measuredNothing` then refuses
    /// the row a view for ever, `needsMeasuring` refuses to ask again, and `isGuessed` does not
    /// even count it, because the cache and the table agree perfectly about nothing. A row
    /// silenced by one bad measurement is gone until the pane changes width, which is the one
    /// thing that marks every key stale.
    ///
    /// So this records each one WITH the geometry of the pass that took it, because the question
    /// a report has to answer is not how many but which frame. `TranscriptRowInk` is what says
    /// the row was expected to draw: a row that claims to draw nothing measuring nothing is the
    /// design working and is not recorded here.
    static func silenced(_ silence: Silence) {
        silencedRows += 1
        guard silences.count < mostSilences else { return }
        silences.append(silence)
    }

    /// One row, and the pane it was measured against.
    struct Silence: Sendable {
        var row: Int
        var source: String
        var shape: String
        var columnWidth: Double
        var viewportWidth: Double
        var viewportHeight: Double
    }

    /// A run that silences a thousand rows should not write a thousand of these into a report
    /// nobody can read. `silencedRows` still counts them all.
    private static let mostSilences = 200

    /// One batch of corrections, and the ones that did not take.
    static func corrected(rows: Int, uncorrected: Int) {
        correctedRows += rows
        uncorrectedRows += uncorrected
    }

    static func reset() {
        holds = 0
        underAHand = 0
        underLiveResize = 0
        liveResizes = 0
        arrivals = 0
        reveals = 0
        measurements = 0
        estimatedRows = 0
        correctedRows = 0
        uncorrectedRows = 0
        screenEstimated = 0
        screenWrong = 0
        screensSeen = 0
        screenEstimatedSettled = 0
        screenWrongSettled = 0
        noteCalls = 0
        notedRows = 0
        placeWrites = 0
        cellsAsked = 0
        cellsBuilt = 0
        cellSeconds = 0
        cellWorstMs = 0
        heightAsks = 0
        noteSeconds = 0
        noteWorstMs = 0
        entryPasses = 0
        entriesBuilt = 0
        silencedRows = 0
        silences = []
    }

    static func summary() -> [String: Double] {
        [
            "holds": Double(holds),
            "underAHand": Double(underAHand),
            "underLiveResize": Double(underLiveResize),
            "liveResizes": Double(liveResizes),
            "arrivals": Double(arrivals),
            "reveals": Double(reveals),
            "measurements": Double(measurements),
            "estimatedRows": Double(estimatedRows),
            "correctedRows": Double(correctedRows),
            "uncorrectedRows": Double(uncorrectedRows),
            "screenEstimated": Double(screenEstimated),
            "screenWrong": Double(screenWrong),
            "screensSeen": Double(screensSeen),
            "screenEstimatedSettled": Double(screenEstimatedSettled),
            "screenWrongSettled": Double(screenWrongSettled),
            "noteCalls": Double(noteCalls),
            "notedRows": Double(notedRows),
            "placeWrites": Double(placeWrites),
            "cellsAsked": Double(cellsAsked),
            "cellsBuilt": Double(cellsBuilt),
            "cellSeconds": cellSeconds,
            "cellWorstMs": cellWorstMs,
            "heightAsks": Double(heightAsks),
            "noteSeconds": noteSeconds,
            "noteWorstMs": noteWorstMs,
            "entryPasses": Double(entryPasses),
            "entriesBuilt": Double(entriesBuilt),
            "silencedRows": Double(silencedRows),
        ]
    }
}
