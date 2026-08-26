import AppKit
import SwiftUI
import QuartzCore
import BloomCore

/// Measures how many frames the window produces while a long transcript is scrolled.
///
/// The fourth of the family, after `FrameProbe` (a divider drag), `SwitchProbe` (a workspace) and
/// `TabProbe` (a tab). It exists because the owner's complaint is that a chat does not scroll
/// smoothly, and until now nothing in the app could answer that with a number. Everything the
/// other three write down about impressions applies here: "it stutters" cannot say whether the
/// cost is in markdown being re-parsed, in a row measuring itself, in the diff attachments, or in
/// a release build doing exactly what it should and the impression being about something else.
///
/// **One driver, and programmatic.** `TabProbe`'s reasoning holds and is not repeated: the owner
/// may be at this Mac, and a probe that posted scroll wheel events would need the window in front
/// and would take his input. This one moves the scroll view's own origin from inside the display
/// link callback, a fixed number of points per frame, so a run needs no pointer and no focus. It
/// measures what layout and drawing cost per frame, which is the part a hand cannot make faster.
///
/// What it deliberately does NOT measure: the momentum curve AppKit applies to a real trackpad
/// flick. That is AppKit's, it is the same in every application, and it is not what anybody means
/// by a chat that scrolls badly.
///
///     Bloom --scroll-probe /tmp/scroll.json --scroll-workspace <id>
///           [--scroll-sweeps 4] [--scroll-step 24] [--window-size 1440x900]
///
/// A sweep is one trip from the bottom of the transcript to the top and back. `--scroll-step` is
/// how far the origin moves per frame: 24 points at 120Hz is about 2,900 points a second, which is
/// a brisk flick rather than a drag, and is the speed at which a row that lays out slowly shows.
///
/// Everything that is not the scroll itself is `ProbeHarness`: the flags, the window, the failure,
/// the frame timings, the report.
@MainActor
enum ScrollProbe {
    private static let harness = ProbeHarness(subject: "scroll")

    static var isRequested: Bool { harness.isRequested }

    // MARK: - Arguments

    private static var workspace: String? { ProbeHarness.value(for: "--scroll-workspace") }
    private static var sweeps: Int { ProbeHarness.count("--scroll-sweeps", or: 4) }
    /// `--scroll-warm 0`: measure the first trip rather than the one after it. See `run`.
    private static var warm: Bool { ProbeHarness.count("--scroll-warm", or: 1) != 0 }
    /// `--scroll-composer 400`: grow the composer to this many points instead of scrolling.
    private static var composer: Double? { ProbeHarness.value(for: "--scroll-composer").flatMap(Double.init) }
    private static var step: CGFloat { ProbeHarness.points("--scroll-step", or: 24) }

    // MARK: - Entry

    static func schedule() {
        Task { @MainActor in await run() }
    }

    private static func run() async {
        // Not brought to the front, for the reason at the head of `ProbeHarness.window`.
        let (window, contentView) = await harness.window()

        // Before the conversation is opened, so the arrival is in the count. `uncorrectedRows` is
        // the one to read: a row the table draws at a height the row did not report is the white
        // gap between rows. See `TranscriptHoldCensus`.
        TranscriptHoldCensus.reset()

        if let workspace {
            OpenWorkspaceNotification.post(WorkspaceID(workspace))
            // Long enough for the transcript to load every row and for the inspector to settle.
            try? await Task.sleep(for: .seconds(8))
        }

        guard let scroll = ProbeHarness.transcriptScrollView(in: contentView) else {
            // What was on screen instead, because "no transcript" is usually a run that attached
            // to the wrong window: the welcome window on a fresh defaults domain is one.
            let windows = NSApp.windows.map { "\($0.title) \($0.frame)" }
            FileHandle.standardError.write(Data("windows: \(windows)\n".utf8))
            harness.fail("no transcript NSScrollView found")
        }

        if let composer {
            await growComposer(to: composer, scroll: scroll)
            harness.write(report(
                recorder: FrameRecorder(view: contentView) { 0 }, travel: 0, wall: 0,
                window: window, scroll: scroll, heightBefore: scroll.documentView?.frame.height ?? 0
            ))
            exit(0)
        }

        // Sampled before the sweep and again in the report, because these two disagreeing is
        // itself a finding: a transcript whose content height changes while it is being scrolled
        // is one whose rows are still being measured, and every one of those measurements lands
        // on the main thread inside a frame somebody is waiting for.
        let heightBefore = scroll.documentView?.frame.height ?? 0
        guard scroll.endOffset > 1 else {
            harness.fail("the transcript is shorter than its viewport, so there is nothing to scroll")
        }

        // The offset, sampled once a frame. A run whose min and max agree scrolled nothing, which
        // is the failure this catches: SwiftUI's own `ScrollPosition` pins the transcript to the
        // bottom while a turn is running, and a pin fights an origin written from underneath it.
        let recorder = FrameRecorder(view: contentView) { [weak scroll] in
            scroll?.contentView.bounds.origin.y ?? 0
        }

        // A warm pass that is thrown away. The first trip through a long transcript pays for every
        // row's first layout, and reporting that as the steady state would overstate every number.
        //
        // **`--scroll-warm 0` keeps that trip instead, and it is the one being complained about.**
        // "The higher I go up, the more stuttery it gets" is about the pass that draws every row
        // for the first time. A warmed run measures the pass after it, where there is nothing left
        // to put right: the upward leg of one made a single `noteHeightOfRows` call in two hundred
        // frames, which is a steady state and not the question.
        if warm {
            await sweep(scroll, travel: scroll.endOffset, sweeps: 1)
            try? await Task.sleep(for: .seconds(1))
        }

        await documentToStopChanging(scroll)

        // **Read here rather than on arrival.** The history lands a beat after the tail, so an end
        // sampled before that names a document a fraction of its final height: a run that took
        // 7,722 points swept the last eighth of a 32,600 point conversation and never went near
        // the top, which is the half being asked about.
        let travel = scroll.endOffset

        harness.markStarted()

        // **Where a frame's time went, not just how long it took.** The complaint is stuttering
        // rather than a low frame rate, so the question is which pass is eating a frame, and the
        // centre column's layout is the candidate: a body pass over this list rebuilds an entry
        // for every row in the window. `SwitchProbe` and `TabProbe` have read this for months and
        // the scroll probe never turned it on, which is why an upward sweep could say 62ms at the
        // ninety fifth percentile and not say what took it.
        PaneLayoutTiming.reset()
        PaneLayoutTiming.isEnabled = true

        recorder.start()
        documentHeights.removeAll()
        frames.removeAll()
        let wallBefore = CACurrentMediaTime()
        await sweep(scroll, travel: travel, sweeps: sweeps)
        let wall = CACurrentMediaTime() - wallBefore
        recorder.stop()
        PaneLayoutTiming.isEnabled = false

        harness.write(report(
            recorder: recorder, travel: travel, wall: wall, window: window, scroll: scroll,
            heightBefore: heightBefore
        ))
        exit(0)
    }

    /// **The owner's own reproduction, without his hand on the divider.**
    ///
    /// "When I resize the editor to be higher, the chat content will get empty lines as well." The
    /// composer's height is `@AppStorage("composer.editorHeight")`, so the gesture is a write to
    /// that key: the box grows, the transcript above it gets shorter, and nothing about its width
    /// moves. Nothing is scrolled here on purpose, because a sweep would draw every row it passed
    /// and correct exactly what this is trying to catch.
    ///
    /// The nudge is what makes the census speak. It is taken on a movement of the clip view, so a
    /// point down and back is how a run asks for one.
    private static func growComposer(to points: Double, scroll: NSScrollView) async {
        nudge(scroll)
        try? await Task.sleep(for: .seconds(1))
        UserDefaults.standard.set(points, forKey: "composer.editorHeight")
        try? await Task.sleep(for: .seconds(3))
        nudge(scroll)
        try? await Task.sleep(for: .seconds(1))
    }

    /// **The arrival is not the gesture, and `documentMoves` was counting it.**
    ///
    /// A session's history lands a beat after its tail, as one insert of some two thousand rows,
    /// and the document grows by the whole height of them on that frame. Whether that fell inside
    /// the measured window or just before it was a matter of timing, and it moved the reported
    /// worst move between 8,035 and 32,218 points across three runs of builds that differed in
    /// ways that could not account for it. Worse, it cannot be improved: the rows really are that
    /// tall, so a perfect estimate produces the same jump, and on the run that prompted this the
    /// arithmetic came to 28,779 against a reported worst of 24,795. A number with a floor above
    /// the value being reported is not measuring the thing it is named for.
    ///
    /// So a run waits for the document to stop changing before it starts counting. What is left is
    /// what SCROLLING does to it, which is the question.
    private static func documentToStopChanging(_ scroll: NSScrollView) async {
        var last = scroll.documentView?.frame.height ?? 0
        var still = 0
        // Ten seconds at the outside. A conversation still growing after that is a running turn,
        // and a run measures what it finds rather than waiting for a turn to end.
        for _ in 0..<100 {
            try? await Task.sleep(for: .milliseconds(100))
            let now = scroll.documentView?.frame.height ?? 0
            still = abs(now - last) <= 0.5 ? still + 1 : 0
            last = now
            // Half a second of not moving. Long enough to be past the insert, short enough that a
            // run does not spend its time here.
            if still >= 5 { return }
        }
    }

    /// **"The higher I go up, the more stuttery it gets", as a number.**
    ///
    /// The upward frames only, split into five bands by how far up the document they were, from
    /// the live end to the top. For each band: the median gap between frames, and what the table
    /// was asked to do in them. A cost that climbs band by band is the complaint; a flat one says
    /// the feeling is somewhere else.
    ///
    /// Bands rather than a correlation because the answer has to be readable in a report, and
    /// five of them because a sweep is a few hundred frames and fewer than fifty a band is noise.
    private static func climb() -> [String: JSONValue] {
        // Downwards is the sweep's return leg and is not the gesture being complained about.
        var upward: [(Frame, Double)] = []
        for (index, frame) in frames.enumerated() where index > 0 {
            let previous = frames[index - 1]
            guard frame.offset < previous.offset else { continue }
            upward.append((frame, (frame.at - previous.at) * 1000))
        }
        guard upward.count >= 25 else { return ["climbBands": .array([])] }
        let top = upward.map(\.0.offset).max() ?? 1
        let bands = 5
        var out: [JSONValue] = []
        for band in 0..<bands {
            // Band 0 is nearest the live end, band 4 is the top of the conversation.
            let high = top * Double(bands - band) / Double(bands)
            let low = top * Double(bands - band - 1) / Double(bands)
            let inBand = upward.filter { $0.0.offset <= high && $0.0.offset > low }
            guard !inBand.isEmpty else { continue }
            let gaps = inBand.map(\.1).sorted()
            let calls = (inBand.last?.0.noteCalls ?? 0) - (inBand.first?.0.noteCalls ?? 0)
            let rows = (inBand.last?.0.notedRows ?? 0) - (inBand.first?.0.notedRows ?? 0)
            out.append(.object([
                "band": .integer(band),
                "fromEnd": .number(low),
                "frames": .integer(inBand.count),
                "medianMs": .number(ProbeStats.percentile(0.5, of: gaps)),
                "p95Ms": .number(ProbeStats.percentile(0.95, of: gaps)),
                "noteCalls": .integer(abs(calls)),
                "notedRows": .integer(abs(rows)),
            ]))
        }
        return ["climbBands": .array(out)]
    }

    /// How much the document resized while the sweep was running.
    private static func documentMovement() -> [String: JSONValue] {
        let heights = documentHeights
        var moves = 0
        var worst: CGFloat = 0
        for (index, height) in heights.enumerated() where index > 0 {
            let step = abs(height - heights[index - 1])
            if step > 0.5 {
                moves += 1
                worst = max(worst, step)
            }
        }
        return [
            "documentMoves": .integer(moves),
            "documentMovedShare":
                .number(heights.isEmpty ? 0 : Double(moves) / Double(heights.count)),
            "worstDocumentMove": .number(Double(worst)),
            "documentSweepMin": .number(Double(heights.min() ?? 0)),
            "documentSweepMax": .number(Double(heights.max() ?? 0)),
        ]
    }

    private static func nudge(_ scroll: NSScrollView) {
        let origin = scroll.contentView.bounds.origin
        scroll.contentView.setBoundsOrigin(CGPoint(x: origin.x, y: max(0, origin.y - 1)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: - Driving

    /// One sweep is bottom to top and back, moved `step` points per vsync.
    ///
    /// Written straight onto the clip view's bounds rather than through `scroll(to:)`, because the
    /// latter goes through AppKit's own animation for some callers and an animated scroll measures
    /// the animation. `reflectScrolledClipView` is what tells the scroll view its origin moved,
    /// and without it the scrollers and anything observing the offset never hear about the move.
    private static func sweep(_ scroll: NSScrollView, travel: CGFloat, sweeps: Int) async {
        for _ in 0..<sweeps {
            await travelTo(scroll, from: travel, to: 0)
            await travelTo(scroll, from: 0, to: travel)
        }
    }

    /// The document's own height, sampled once a frame while the sweep runs.
    ///
    /// **This is the thing being felt.** The complaint is not a frame rate: it is that the content
    /// keeps resizing under the hand. A document whose height moves during a sweep is a transcript
    /// still finding out how tall it is, and every move of it shifts everything below the row that
    /// changed.
    private static var documentHeights: [CGFloat] = []

    /// One frame of a sweep: where it was, when it was, and what the table had been asked to do by
    /// then. See `climb`, which is the whole reason this is kept per frame rather than summed.
    private struct Frame {
        var offset: CGFloat
        var at: Double
        var noteCalls: Int
        var notedRows: Int
    }

    private static var frames: [Frame] = []

    private static func travelTo(_ scroll: NSScrollView, from: CGFloat, to: CGFloat) async {
        let direction: CGFloat = to > from ? 1 : -1
        var offset = from
        while (direction > 0 && offset < to) || (direction < 0 && offset > to) {
            offset += step * direction
            offset = direction > 0 ? min(offset, to) : max(offset, to)
            scroll.contentView.setBoundsOrigin(
                CGPoint(x: scroll.contentView.bounds.origin.x, y: offset)
            )
            scroll.reflectScrolledClipView(scroll.contentView)
            documentHeights.append(scroll.documentView?.frame.height ?? 0)
            // Where this frame was, and what the table was asked to do during it. See `climb`.
            frames.append(Frame(
                offset: offset,
                at: CACurrentMediaTime(),
                noteCalls: TranscriptHoldCensus.noteCalls,
                notedRows: TranscriptHoldCensus.notedRows
            ))
            // One vsync. Sleeping rather than driving from the display link callback keeps the
            // callback doing nothing but reading the clock, which is what makes the gap between
            // two of its ticks the honest cost of a frame.
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    // MARK: - Reporting

    private static func report(
        recorder: FrameRecorder, travel: CGFloat, wall: Double, window: NSWindow,
        scroll: NSScrollView, heightBefore: CGFloat
    ) -> JSONValue {
        let offsets = recorder.widths
        let own: [String: JSONValue] = [
            "wallSeconds": .number(wall),
            "travelPoints": .number(Double(travel)),
            "documentHeightBefore": .number(Double(heightBefore)),
            "documentHeightAfter": .number(Double(scroll.documentView?.frame.height ?? 0)),
            "viewportHeight": .number(Double(scroll.contentView.bounds.height)),
            "offsetMin": .number(Double(offsets.min() ?? 0)),
            "offsetMax": .number(Double(offsets.max() ?? 0)),
            // The check that a run actually moved. See the note on the recorder above.
            "didScroll": .bool((offsets.max() ?? 0) - (offsets.min() ?? 0) > 1),
            "step": .number(Double(step)),
            "sweeps": .integer(sweeps),
            "transcriptHold": .map(TranscriptHoldCensus.summary()),
            // `detail` is the centre column, which is the one holding the transcript. Each entry
            // is `[startedMs, tookMs]`, so a pass can be laid against the frame it landed in.
            "paneLayout": .map(PaneLayoutTiming.summary()),
            "panePasses": .map(PaneLayoutTiming.timeline()),
        ].merging(documentMovement()) { mine, _ in mine }
            .merging(climb()) { mine, _ in mine }
        // The probe's own keys win over both, so a report that has an opinion keeps it.
        return .object(
            own
                .merging(ProbeHarness.frameTimings(recorder.intervals.map { $0 * 1000 })) { mine, _ in mine }
                .merging(harness.conditions(window: window)) { mine, _ in mine }
        )
    }
}
