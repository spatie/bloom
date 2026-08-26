import AppKit
import SwiftUI
import QuartzCore
import BloomCore

/// Measures how many frames the window actually produces while the sidebar divider is dragged.
///
/// This exists because "it feels like 20fps" is an impression, and an impression cannot tell you
/// whether the cost is in the sidebar's rows, in the two columns that change width behind it, or
/// in a debug build's unoptimised SwiftUI. A number can.
///
/// How the number is taken. A `CADisplayLink` fires on the main thread once per vsync, in the
/// common run loop modes so it keeps firing inside the nested event tracking loop a divider drag
/// runs in. Its callback does nothing but record `CACurrentMediaTime()`. When the main thread is
/// busy laying out, the callback cannot run, so the gap between two records IS the time one frame
/// took. That is the same quantity a user sees as smoothness, and unlike a display link's own
/// `timestamp` it cannot be fooled by the link continuing to tick while nothing is drawn.
///
/// Two drivers, because each answers a different objection:
///
/// - `mouse` posts real `CGEvent`s to THIS process's pid, so AppKit's own divider tracking, live
///   resize flags and event coalescing are all exercised exactly as they are under a hand. It is
///   the faithful one. It never goes near another application: `postToPid` takes a pid.
/// - `programmatic` calls `setPosition(_:ofDividerAt:)` from the display link callback, so a run
///   is deterministic, needs no input at all, and cannot be blamed on synthetic events being
///   delivered differently. It is the one to compare two builds with.
///
///     Bloom --frame-probe /tmp/probe.json [--probe-driver mouse|programmatic]
///           [--probe-select <workspaceID>] [--window-size 1440x900] [--probe-sweeps 6]
///
/// Everything that is not the drag itself is `ProbeHarness`: the flags, the window, the failure,
/// the report.
@MainActor
enum FrameProbe {
    private static let harness = ProbeHarness(subject: "frame")

    static var isRequested: Bool { harness.isRequested }

    // MARK: - Arguments

    private static var driver: String { ProbeHarness.text("--probe-driver", or: "mouse") }

    /// Window state a run wants to start in, so the inspector can be taken out of the picture and
    /// the centre column measured on its own. Read by `AppModel`, which owns the switch.
    static var wantsInspector: Bool { !ProbeHarness.isPresent("--probe-no-inspector") }
    private static var sweeps: Int { ProbeHarness.count("--probe-sweeps", or: 6) }
    private static var selection: String? { ProbeHarness.value(for: "--probe-select") }

    /// What the run drags. The sidebar divider, which is what this probe was written for, or the
    /// window's own bottom right corner, which is the gesture the owner called janky.
    ///
    /// A separate flag rather than a fourth driver, because the two gestures cross with the same
    /// three drivers: a window can be resized by a synthetic hand, at a hand's pace from code, or
    /// as fast as the run loop will take it.
    private static var gesture: String { ProbeHarness.text("--probe-gesture", or: "sidebar") }

    /// A pane to open on the selected workspace before anything is measured, so a run can name
    /// what is on screen instead of inheriting whatever the last one left there.
    private static var requestedPane: PaneKind? {
        ProbeHarness.value(for: "--probe-pane").flatMap(PaneKind.init(rawValue:))
    }

    /// Where a browser pane opened by `--probe-pane browser` should go. A file URL by preference:
    /// a run that has to reach the network measures the network.
    private static var paneURL: String { ProbeHarness.text("--probe-url", or: "") }

    // MARK: - Entry

    static func schedule() {
        Task { @MainActor in await run() }
    }

    private static func run() async {
        // The app is deliberately not brought to the front. A probe run happens while the owner is
        // using their own copy, and an activation would steal their keyboard. See `ProbeHarness`,
        // which waits out the launch and applies `--window-size`.
        let (window, contentView) = await harness.window()

        if let selection {
            OpenWorkspaceNotification.post(WorkspaceID(selection))
            // Long enough for the transcript to load and the inspector to fetch its diff.
            try? await Task.sleep(for: .seconds(6))
        }

        if let requestedPane { await openPane(requestedPane) }

        // Everything asynchronous that a fresh launch kicks off (status polls, git reads, the
        // first diff) settles here rather than inside the measurement.
        try? await Task.sleep(for: .seconds(4))

        var split: NSSplitView?
        if gesture != "window" {
            guard let found = sidebarSplitView(in: contentView) else {
                harness.fail("no sidebar NSSplitView found")
            }
            guard found.arrangedSubviews.count >= 2 else {
                harness.fail("sidebar split view has \(found.arrangedSubviews.count) panes")
            }
            split = found
        }

        // What the run is supposed to be moving, sampled once a frame: the sidebar's width, or
        // the window's. A run whose min and max agree measured a window standing still.
        let recorder = FrameRecorder(view: contentView) { [weak split, weak window] in
            gesture == "window"
                ? (window?.frame.width ?? 0)
                : (split?.arrangedSubviews.first?.frame.width ?? 0)
        }

        // A warm pass that is thrown away. The first drag of a launch pays for lazily built
        // layout caches, and reporting that as the steady state would overstate every number.
        await drag(split: split, window: window, sweeps: 1, recorder: nil)
        try? await Task.sleep(for: .seconds(1))

        harness.markStarted()

        PaneLayoutTiming.reset()
        PaneLayoutTiming.isEnabled = true
        TranscriptHoldCensus.reset()
        recorder.start()
        let cpuBefore = ProbeHarness.mainThreadCPUSeconds()
        let wallBefore = CACurrentMediaTime()
        await drag(split: split, window: window, sweeps: sweeps, recorder: recorder)
        mainThreadCPU = ProbeHarness.mainThreadCPUSeconds() - cpuBefore
        wallClock = CACurrentMediaTime() - wallBefore
        recorder.stop()
        PaneLayoutTiming.isEnabled = false

        harness.write(report(recorder: recorder, window: window, split: split))
        exit(0)
    }

    // MARK: - Finding the divider

    /// The `NSSplitView` that `NavigationSplitView` builds, as opposed to the one
    /// `DetailSplitViewController` builds for the centre column and the inspector.
    ///
    /// Identified by containment rather than by class name or by width: the sidebar's split view
    /// is the one that has the other inside it. A private SwiftUI class name would be a guess that
    /// a future release silently breaks.
    private static func sidebarSplitView(in root: NSView) -> NSSplitView? {
        var found: [NSSplitView] = []
        func walk(_ view: NSView) {
            if let split = view as? NSSplitView { found.append(split) }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        guard !found.isEmpty else { return nil }
        // The outermost one: not a descendant of any other candidate.
        return found.first { candidate in
            !found.contains { other in other !== candidate && candidate.isDescendant(of: other) }
        } ?? found.first
    }

    /// Where the divider sits, in the split view's own coordinates.
    private static func dividerX(_ split: NSSplitView) -> CGFloat {
        let first = split.arrangedSubviews[0]
        return first.frame.maxX + split.dividerThickness / 2
    }

    // MARK: - Drivers

    private static func drag(
        split: NSSplitView?, window: NSWindow, sweeps: Int, recorder: FrameRecorder?
    ) async {
        if gesture == "window" {
            switch driver {
            case "programmatic": await resizeWindow(window, sweeps: sweeps, paced: true)
            case "throughput": await resizeWindow(window, sweeps: sweeps, paced: false)
            default: await resizeWindowWithMouse(window, sweeps: sweeps)
            }
            return
        }
        guard let split else { return }
        switch driver {
        case "programmatic": await dragProgrammatically(split: split, sweeps: sweeps, paced: true)
        case "throughput": await dragProgrammatically(split: split, sweeps: sweeps, paced: false)
        default: await dragWithMouse(split: split, window: window, sweeps: sweeps)
        }
    }

    // MARK: - The window's own edge

    /// Narrows the window by `travel` and widens it back, `sweeps` times.
    ///
    /// The frame is set rather than the content size, and the top left corner is held still, so
    /// this is the same geometry a hand dragging the bottom right corner produces: the title bar
    /// does not move and the window grows to the right.
    ///
    /// `display: true` is what makes a step cost what a frame of a drag costs. Without it AppKit
    /// is free to defer the layout, and a hundred steps collapse into one.
    private static func resizeWindow(_ window: NSWindow, sweeps: Int, paced: Bool) async {
        let start = window.frame
        for offset in sweepOffsets(sweeps: sweeps) {
            var frame = start
            frame.size.width = start.width + offset
            window.setFrame(frame, display: true)
            if paced {
                try? await Task.sleep(for: .microseconds(8_333))
            } else {
                await nextRunLoopTurn()
            }
        }
        window.setFrame(start, display: true)
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// The same travel, driven by real events on the window's bottom right corner, so AppKit's own
    /// live resize path runs: `inLiveResize`, the resize increments, the layer backed redraw and
    /// whatever coalescing the window server does under a hand.
    private static func resizeWindowWithMouse(_ window: NSWindow, sweeps: Int) async {
        guard let screen = window.screen ?? NSScreen.main else { return }
        // Two points inside the corner, because the resize region straddles the frame edge and a
        // press exactly on it is as likely to land outside the window as in it.
        let corner = CGPoint(x: window.frame.maxX - 2, y: window.frame.minY + 2)
        let flipped = CGPoint(x: corner.x, y: screen.frame.maxY - corner.y)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(400))

        let pid = ProcessInfo.processInfo.processIdentifier
        let sequence = sweepOffsets(sweeps: sweeps)
        await harness.onEventThread(polling: .milliseconds(4)) {
            ProbeHarness.post(.leftMouseDown, at: flipped, pid: pid)
            Thread.sleep(forTimeInterval: 0.05)
            for offset in sequence {
                ProbeHarness.post(
                    .leftMouseDragged, at: CGPoint(x: flipped.x + offset, y: flipped.y), pid: pid
                )
                Thread.sleep(forTimeInterval: 1.0 / 120.0)
            }
            ProbeHarness.post(.leftMouseUp, at: flipped, pid: pid)
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// Opens a pane of the given kind on the selected workspace, exactly as the File menu does,
    /// and waits for it to settle.
    private static func openPane(_ kind: PaneKind) async {
        guard let workspace = AppModel.probeSelectedModel else { return }
        NewPane.open(kind, in: workspace, url: paneURL) {
            WorkspaceTabsStore.shared.select($0, in: workspace)
        }
        // A browser has a page to load and a terminal has a shell to fork.
        try? await Task.sleep(for: .seconds(kind == .chat ? 3 : 6))
    }

    /// The travel of one sweep, in points, taken INWARDS from wherever the divider starts.
    ///
    /// Inwards rather than outwards because the sidebar column declares a 200...420 range and the
    /// remembered width is 400: a sweep that widened the pane spent five of its six sweeps parked
    /// against the 420 limit, where nothing re-lays out and the probe reported a frame rate for a
    /// window that was standing still. Measured: 11 distinct widths across 101 frames.
    private static let travel: CGFloat = 150

    private static func dragWithMouse(split: NSSplitView, window: NSWindow, sweeps: Int) async {
        let start = dividerX(split)
        let pointInSplit = CGPoint(x: start, y: split.bounds.midY)
        let inWindow = split.convert(pointInSplit, to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)

        // CGEvent works in a top-left origin space, where AppKit works in bottom-left.
        guard let screen = window.screen ?? NSScreen.main else { return }
        let flipped = CGPoint(x: onScreen.x, y: screen.frame.maxY - onScreen.y)

        let sequence = sweepOffsets(sweeps: sweeps)

        // The app has to be frontmost for this driver and only for this driver.
        //
        // A click into a window whose app is not active is consumed by the activation itself:
        // `NSSplitView`'s divider does not accept a first mouse, so the drag that followed moved
        // nothing at all and the probe reported a flawless 120fps for a window standing still.
        // Measured: 1050 frames at 8.36ms with the sidebar at 400 points from first sample to
        // last. The programmatic driver exists so that the A/B runs need none of this.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(400))

        // Posted at a steady 120Hz, which is what a trackpad on this machine delivers. See
        // `ProbeHarness.onEventThread` for why the posting is not done from here.
        let pid = ProcessInfo.processInfo.processIdentifier
        await harness.onEventThread(polling: .milliseconds(4)) {
            ProbeHarness.post(.leftMouseDown, at: flipped, pid: pid)
            Thread.sleep(forTimeInterval: 0.05)
            for offset in sequence {
                let point = CGPoint(x: flipped.x + offset, y: flipped.y)
                ProbeHarness.post(.leftMouseDragged, at: point, pid: pid)
                Thread.sleep(forTimeInterval: 1.0 / 120.0)
            }
            ProbeHarness.post(.leftMouseUp, at: CGPoint(x: flipped.x, y: flipped.y), pid: pid)
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// Two modes, because they answer two different questions and neither answers both.
    ///
    /// Paced issues one move every 8.33ms, the rate a trackpad reports at on this display, so the
    /// frame intervals it records are what a hand would feel. Its wall clock includes whatever the
    /// sleeps overran by, so on a loaded machine it says as much about the machine as about the
    /// app.
    ///
    /// Unpaced issues the next move as soon as the last one returns. It says nothing about
    /// smoothness, and it is the only one of the two whose cost per step can be compared between
    /// two builds on a machine with three other agents building on it, because there is no idle
    /// time in it for the machine's load to leak into.
    private static func dragProgrammatically(
        split: NSSplitView, sweeps: Int, paced: Bool
    ) async {
        let start = dividerX(split)
        let sequence = sweepOffsets(sweeps: sweeps)
        for offset in sequence {
            split.setPosition(start + offset, ofDividerAt: 0)
            if paced {
                try? await Task.sleep(for: .microseconds(8_333))
            } else {
                // Still a hop through the run loop, so the display cycle that draws the frame
                // actually runs. Without it AppKit coalesces six hundred moves into one layout
                // and the probe measures nothing at all.
                await nextRunLoopTurn()
            }
        }
        split.setPosition(start, ofDividerAt: 0)
        try? await Task.sleep(for: .milliseconds(300))
    }

    private static func nextRunLoopTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// A triangle wave: in and back out, `sweeps` times, two points of travel per step.
    ///
    /// Two points per step at 120Hz is 240 points a second, which is an unhurried drag rather
    /// than a flick, so nothing here is measuring a rate no hand would produce.
    private static func sweepOffsets(sweeps: Int) -> [CGFloat] {
        var offsets: [CGFloat] = []
        let step: CGFloat = 2
        for _ in 0..<sweeps {
            var x: CGFloat = 0
            while x > -travel { offsets.append(x); x -= step }
            while x < 0 { offsets.append(x); x += step }
        }
        return offsets
    }

    // MARK: - Reporting

    /// The one report in the family that counts frames against a fixed deadline.
    ///
    /// `framesOver16ms` and `framesOver33ms` are 60Hz and 30Hz, and they stay literals here where
    /// `ScrollProbe` and `ResizeProbe` measure against their own median. This probe's question is
    /// whether a drag holds a frame budget; theirs is whether a run stuttered against whatever
    /// this panel is doing. See `ProbeHarness.frameTimings`.
    private static func report(
        recorder: FrameRecorder, window: NSWindow, split: NSSplitView?
    ) -> JSONValue {
        let intervals = recorder.intervals.map { $0 * 1000 }
        let sorted = intervals.sorted()
        func percentile(_ fraction: Double) -> Double {
            ProbeStats.percentile(fraction, of: sorted)
        }
        let total = intervals.reduce(0, +)
        let mean = intervals.isEmpty ? 0 : total / Double(intervals.count)
        let steps = sweepOffsets(sweeps: sweeps).count

        let own: [String: JSONValue] = [
            "driver": .string(driver),
            "gesture": .string(gesture),
            "pane": .string(requestedPane?.rawValue ?? "whatever was open"),
            "selection": .string(selection ?? "home"),
            "drawnRows": .integer(TranscriptDrawn.rows),
            // What the window is ACTUALLY showing, rather than what was asked for. `AppModel`
            // reselects the last workspace on launch, so a run that meant to measure Home
            // silently measured a workspace as soon as any earlier run had opened one, and the
            // two configurations converged on the same number for a reason that had nothing to do
            // with either of them.
            "inspector": .bool(wantsInspector),
            "restoredWorkspace": .string(
                UserDefaults.standard.string(forKey: "sidebar.lastWorkspaceID") ?? "none"
            ),
            "frames": .integer(intervals.count),
            "durationMs": .number(total),
            "meanMs": .number(mean),
            "meanFps": .number(mean > 0 ? 1000 / mean : 0),
            "medianMs": .number(percentile(0.5)),
            "medianFps": .number(percentile(0.5) > 0 ? 1000 / percentile(0.5) : 0),
            "p95Ms": .number(percentile(0.95)),
            "p99Ms": .number(percentile(0.99)),
            "maxMs": .number(sorted.last ?? 0),
            "framesOver16ms": .integer(intervals.filter { $0 > 16.7 }.count),
            "framesOver33ms": .integer(intervals.filter { $0 > 33.4 }.count),
            "sidebarWidth": .number(Double(split?.arrangedSubviews[0].frame.width ?? 0)),
            // Proof the drag landed. A run whose min and max are the same measured nothing.
            "widthMin": .number(Double(recorder.widths.min() ?? 0)),
            "widthMax": .number(Double(recorder.widths.max() ?? 0)),
            "widthSteps": .integer(Set(recorder.widths).count),
            "dragSteps": .integer(steps),
            "mainThreadCpuMs": .number(mainThreadCPU * 1000),
            "wallMs": .number(wallClock * 1000),
            "mainThreadBusyFraction": .number(wallClock > 0 ? mainThreadCPU / wallClock : 0),
            "cpuMsPerStep": .number(mainThreadCPU * 1000 / Double(max(1, steps))),
            "paneLayout": .map(PaneLayoutTiming.summary()),
            // Whether the transcript held still, and whether this gesture is one AppKit calls a
            // live resize. See `TranscriptHoldCensus`.
            "transcriptHold": .map(TranscriptHoldCensus.summary()),
            "histogramMs": .numbers(intervals),
        ]
        // The probe's own keys win, so a report that has an opinion about the window keeps it.
        return .object(own.merging(harness.conditions(window: window)) { mine, _ in mine })
    }

    /// How much CPU the main thread actually burned, and over how long.
    ///
    /// Recorded because a wall clock frame interval is a measurement of this machine as well as of
    /// this app, and this machine has other agents building on it. CPU time per drag step barely
    /// moves when the load average does, so it is the number two builds can be compared with;
    /// the frame interval is the number that says what the drag feels like.
    private static var mainThreadCPU: Double = 0
    private static var wallClock: Double = 0
}
