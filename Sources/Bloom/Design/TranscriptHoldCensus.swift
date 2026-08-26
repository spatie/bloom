import Foundation

/// What the transcript's resize hold did, for a probe to read. See `TranscriptHoldView`.
///
/// Two questions a report has to answer and an impression cannot. **Did the hold engage at all**,
/// which is what tells a run whose frame times improved that they improved for the reason claimed.
/// And **which gestures AppKit calls a live resize**: a window edge does, a SwiftUI `DragGesture`
/// on a pane divider cannot, and whether an `NSSplitView` divider does is a thing to measure on
/// this system rather than to remember from a document.
///
/// Four integers, written where the hold is and read by nothing but a report.
@MainActor
enum TranscriptHoldCensus {
    private(set) static var holds = 0
    private(set) static var underAHand = 0
    private(set) static var underLiveResize = 0
    private(set) static var liveResizes = 0
    /// Rows measured exactly when a hold let go, and rows left holding an estimate. The second is
    /// what the hold buys: they are the `NSHostingView`s a resize used to build.
    private(set) static var measuredRows = 0
    private(set) static var estimatedRows = 0

    static func held(underAHand hand: Bool, liveResize: Bool) {
        holds += 1
        if hand { underAHand += 1 }
        if liveResize { underLiveResize += 1 }
    }

    static func liveResizeBegan() { liveResizes += 1 }

    static func released(measured: Int, estimated: Int) {
        measuredRows += measured
        estimatedRows += estimated
    }

    static func reset() {
        holds = 0
        underAHand = 0
        underLiveResize = 0
        liveResizes = 0
        measuredRows = 0
        estimatedRows = 0
    }

    static func summary() -> [String: Double] {
        [
            "holds": Double(holds),
            "underAHand": Double(underAHand),
            "underLiveResize": Double(underLiveResize),
            "liveResizes": Double(liveResizes),
            "measuredRows": Double(measuredRows),
            "estimatedRows": Double(estimatedRows),
        ]
    }
}
