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
    private static var step: CGFloat { ProbeHarness.points("--scroll-step", or: 24) }

    // MARK: - Entry

    static func schedule() {
        Task { @MainActor in await run() }
    }

    private static func run() async {
        // Not brought to the front, for the reason at the head of `ProbeHarness.window`.
        let (window, contentView) = await harness.window()

        if let workspace {
            OpenWorkspaceNotification.post(WorkspaceID(workspace))
            // Long enough for the transcript to load every row and for the inspector to settle.
            try? await Task.sleep(for: .seconds(8))
        }

        guard let scroll = ProbeHarness.transcriptScrollView(in: contentView) else {
            harness.fail("no transcript NSScrollView found")
        }

        // Sampled before the sweep and again in the report, because these two disagreeing is
        // itself a finding: a transcript whose content height changes while it is being scrolled
        // is one whose rows are still being measured, and every one of those measurements lands
        // on the main thread inside a frame somebody is waiting for.
        let heightBefore = scroll.documentView?.frame.height ?? 0
        let travel = ProbeHarness.scrollableHeight(of: scroll)
        guard travel > 1 else {
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
        await sweep(scroll, travel: travel, sweeps: 1)
        try? await Task.sleep(for: .seconds(1))

        harness.markStarted()

        recorder.start()
        let wallBefore = CACurrentMediaTime()
        await sweep(scroll, travel: travel, sweeps: sweeps)
        let wall = CACurrentMediaTime() - wallBefore
        recorder.stop()

        harness.write(report(
            recorder: recorder, travel: travel, wall: wall, window: window, scroll: scroll,
            heightBefore: heightBefore
        ))
        exit(0)
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
        ]
        // The probe's own keys win over both, so a report that has an opinion keeps it.
        return .object(
            own
                .merging(ProbeHarness.frameTimings(recorder.intervals.map { $0 * 1000 })) { mine, _ in mine }
                .merging(harness.conditions(window: window)) { mine, _ in mine }
        )
    }
}
