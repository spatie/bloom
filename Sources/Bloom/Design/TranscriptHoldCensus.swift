import BloomCore
import Foundation

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
    /// **The check that a row is the height it draws at.** Rows that reported the height they
    /// drew at, and how many of those the table was still drawing at another height a turn after
    /// it was told. See `TranscriptTable.Coordinator.checkCorrected`, which carries the bug.
    private(set) static var correctedRows = 0
    private(set) static var uncorrectedRows = 0
    /// **What is on the screen, and how much of it is a guess.** Sampled on every movement of the
    /// clip view: the most rows the reader could see at once that the table was drawing at a
    /// height nobody has measured, and the most it was drawing at a height that disagrees with
    /// what was measured. Either of them above nought is white space the reader can see.
    private(set) static var screenEstimated = 0
    private(set) static var screenWrong = 0
    private(set) static var screensSeen = 0
    /// The same two on the last screen sampled after the movement stopped, which is what tells a
    /// guess that is being corrected as the reader flies past from one that is simply standing
    /// there. See `TranscriptTable.Coordinator.scheduleSettle`.
    private(set) static var screenEstimatedSettled = 0
    private(set) static var screenWrongSettled = 0

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
        ]
    }
}
