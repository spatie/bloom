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
@MainActor
enum ScrollProbe {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--scroll-probe")
    }

    // MARK: - Arguments

    private static func value(for flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static var outputPath: String {
        value(for: "--scroll-probe") ?? (NSTemporaryDirectory() + "bloom-scroll-probe.json")
    }

    private static var workspace: String? { value(for: "--scroll-workspace") }
    private static var sweeps: Int { Int(value(for: "--scroll-sweeps") ?? "") ?? 4 }
    private static var step: CGFloat { CGFloat(Double(value(for: "--scroll-step") ?? "") ?? 24) }

    private static var windowSize: CGSize? {
        guard let raw = value(for: "--window-size") else { return nil }
        let parts = raw.split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1])
        else { return nil }
        return CGSize(width: width, height: height)
    }

    // MARK: - Entry

    static func schedule() {
        Task { @MainActor in await run() }
    }

    private static func run() async {
        // Not brought to the front, for the reason at the head of `FrameProbe`.
        try? await Task.sleep(for: .seconds(3))

        guard let window = await firstWindow(), let contentView = window.contentView else {
            return fail("no window to probe")
        }

        if let size = windowSize {
            window.setContentSize(size)
            window.layoutIfNeeded()
            try? await Task.sleep(for: .seconds(1))
        }

        if let workspace {
            OpenWorkspaceNotification.post(WorkspaceID(workspace))
            // Long enough for the transcript to load every row and for the inspector to settle.
            try? await Task.sleep(for: .seconds(8))
        }

        guard let scroll = transcriptScrollView(in: contentView) else {
            return fail("no transcript NSScrollView found")
        }

        // Sampled before the sweep and again in the report, because these two disagreeing is
        // itself a finding: a transcript whose content height changes while it is being scrolled
        // is one whose rows are still being measured, and every one of those measurements lands
        // on the main thread inside a frame somebody is waiting for.
        let heightBefore = scroll.documentView?.frame.height ?? 0
        let travel = scrollableHeight(scroll)
        guard travel > 1 else {
            return fail("the transcript is shorter than its viewport, so there is nothing to scroll")
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

        // A marker on disk rather than a line on stderr, so a shell watching for it can start
        // `sample` against this pid at the moment the measured sweep begins instead of profiling
        // twenty seconds of a window loading a transcript. Copied from `FrameProbe`, which needed
        // it for the same reason.
        try? Data("\(ProcessInfo.processInfo.processIdentifier)".utf8)
            .write(to: URL(fileURLWithPath: outputPath + ".started"))

        recorder.start()
        let wallBefore = CACurrentMediaTime()
        await sweep(scroll, travel: travel, sweeps: sweeps)
        let wall = CACurrentMediaTime() - wallBefore
        recorder.stop()

        write(report(
            recorder: recorder, travel: travel, wall: wall, scroll: scroll, heightBefore: heightBefore
        ))
        exit(0)
    }

    private static func firstWindow() async -> NSWindow? {
        for _ in 0..<60 {
            let window = NSApp.windows.first {
                $0.isVisible && $0.contentView != nil && $0.parent == nil
                    && $0.styleMask.contains(.titled)
            }
            if let window { return window }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    // MARK: - Finding the transcript

    /// The transcript's scroll view, picked as the one with the most to scroll.
    ///
    /// By document height rather than by position or by class name. The window holds several
    /// scroll views (the sidebar, the inspector's file list, the transcript, sometimes a diff),
    /// and a private SwiftUI class name would be a guess a future release breaks silently. A
    /// transcript with a few thousand messages in it is an order of magnitude taller than any of
    /// the others, so "the tallest" is not a tie worth worrying about. A run against a workspace
    /// with three messages in it would be measuring the wrong view, and would also be measuring
    /// nothing, which is why an unscrollable answer is a failure rather than a zero.
    private static func transcriptScrollView(in root: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return found.max { scrollableHeight($0) < scrollableHeight($1) }
    }

    private static func scrollableHeight(_ scroll: NSScrollView) -> CGFloat {
        let document = scroll.documentView?.frame.height ?? 0
        return max(0, document - scroll.contentView.bounds.height)
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
        recorder: FrameRecorder, travel: CGFloat, wall: Double, scroll: NSScrollView,
        heightBefore: CGFloat
    ) -> [String: Any] {
        let ms = recorder.intervals.map { $0 * 1000 }.sorted()
        func percentile(_ p: Double) -> Double {
            guard !ms.isEmpty else { return 0 }
            let index = Int((Double(ms.count - 1) * p).rounded())
            return ms[min(max(index, 0), ms.count - 1)]
        }
        let offsets = recorder.widths
        // A frame that took longer than two vsyncs at 120Hz. Not a fixed 16.7, because this Mac
        // may be running at 120Hz, and calling every 10ms frame a stutter on a 60Hz panel would
        // report a problem that nobody can see.
        let refresh = ms.isEmpty ? 8.3 : percentile(0.5)
        let dropped = ms.filter { $0 > refresh * 1.8 }.count

        return [
            "frames": ms.count,
            "wallSeconds": wall,
            "travelPoints": travel,
            "documentHeightBefore": heightBefore,
            "documentHeightAfter": scroll.documentView?.frame.height ?? 0,
            "viewportHeight": scroll.contentView.bounds.height,
            "offsetMin": offsets.min() ?? 0,
            "offsetMax": offsets.max() ?? 0,
            // The check that a run actually moved. See the note on the recorder above.
            "didScroll": (offsets.max() ?? 0) - (offsets.min() ?? 0) > 1,
            "medianMs": percentile(0.5),
            "medianFps": percentile(0.5) > 0 ? 1000 / percentile(0.5) : 0,
            "p95Ms": percentile(0.95),
            "p99Ms": percentile(0.99),
            "worstMs": ms.last ?? 0,
            "droppedFrames": dropped,
            "droppedShare": ms.isEmpty ? 0 : Double(dropped) / Double(ms.count),
            "step": step,
            "sweeps": sweeps,
        ]
    }

    private static func write(_ report: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys]
        ) else { return fail("could not serialise the report") }
        try? data.write(to: URL(fileURLWithPath: outputPath))
    }

    /// Typed as returning nothing rather than `Never`, so `return fail(...)` reads the same in
    /// a guard as it does in the other three probes. It exits either way.
    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("scroll probe: \(message)\n".utf8))
        exit(1)
    }
}
