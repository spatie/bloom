import AppKit
import SwiftUI
import QuartzCore
import Synchronization
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
@MainActor
enum FrameProbe {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--frame-probe")
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
        value(for: "--frame-probe") ?? (NSTemporaryDirectory() + "bloom-frame-probe.json")
    }

    private static var driver: String { value(for: "--probe-driver") ?? "mouse" }

    /// Window state a run wants to start in, so the columns can be taken out of the picture one at
    /// a time. Read by `AppModel`, which owns both switches.
    ///
    /// `--probe-no-inspector` leaves the centre column alone with the sidebar;
    /// `--probe-no-panel` keeps the inspector but drops the terminal inside it.
    static var wantsInspector: Bool { !CommandLine.arguments.contains("--probe-no-inspector") }
    static var wantsBottomPanel: Bool { !CommandLine.arguments.contains("--probe-no-panel") }
    private static var sweeps: Int { Int(value(for: "--probe-sweeps") ?? "") ?? 6 }
    private static var selection: String? { value(for: "--probe-select") }

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
        // The app is deliberately not brought to the front. A probe run happens while the owner is
        // using their own copy, and an activation would steal their keyboard.
        try? await Task.sleep(for: .seconds(3))

        var window: NSWindow?
        for _ in 0..<60 {
            window = NSApp.windows.first {
                $0.isVisible && $0.contentView != nil && $0.parent == nil
                    && $0.styleMask.contains(.titled)
            }
            if window != nil { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let window, let contentView = window.contentView else {
            return fail("no window to probe")
        }

        if let size = windowSize {
            window.setContentSize(size)
            window.layoutIfNeeded()
            try? await Task.sleep(for: .seconds(1))
        }

        if let selection {
            NotificationCenter.default.post(name: .bloomOpenWorkspace, object: selection)
            // Long enough for the transcript to load and the inspector to fetch its diff.
            try? await Task.sleep(for: .seconds(6))
        }

        // Everything asynchronous that a fresh launch kicks off (status polls, git reads, the
        // first diff) settles here rather than inside the measurement.
        try? await Task.sleep(for: .seconds(4))

        guard let split = sidebarSplitView(in: contentView) else {
            return fail("no sidebar NSSplitView found")
        }
        guard split.arrangedSubviews.count >= 2 else {
            return fail("sidebar split view has \(split.arrangedSubviews.count) panes")
        }

        let recorder = FrameRecorder(view: contentView) { [weak split] in
            split?.arrangedSubviews.first?.frame.width ?? 0
        }

        // A warm pass that is thrown away. The first drag of a launch pays for lazily built
        // layout caches, and reporting that as the steady state would overstate every number.
        await drag(split: split, window: window, sweeps: 1, recorder: nil)
        try? await Task.sleep(for: .seconds(1))

        // A marker on disk rather than a line on stderr, so a shell watching for it can start
        // `sample` against this pid at the moment the measured drag begins instead of profiling
        // ten seconds of a window doing nothing.
        try? Data("\(ProcessInfo.processInfo.processIdentifier)".utf8)
            .write(to: URL(fileURLWithPath: outputPath + ".started"))

        PaneLayoutTiming.reset()
        PaneLayoutTiming.isEnabled = true
        recorder.start()
        let cpuBefore = mainThreadCPUSeconds()
        let wallBefore = CACurrentMediaTime()
        await drag(split: split, window: window, sweeps: sweeps, recorder: recorder)
        mainThreadCPU = mainThreadCPUSeconds() - cpuBefore
        wallClock = CACurrentMediaTime() - wallBefore
        recorder.stop()
        PaneLayoutTiming.isEnabled = false

        write(report(recorder: recorder, window: window, split: split))
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
        split: NSSplitView, window: NSWindow, sweeps: Int, recorder: FrameRecorder?
    ) async {
        switch driver {
        case "programmatic": await dragProgrammatically(split: split, sweeps: sweeps, paced: true)
        case "throughput": await dragProgrammatically(split: split, sweeps: sweeps, paced: false)
        default: await dragWithMouse(split: split, window: window, sweeps: sweeps)
        }
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

        // Posted from a thread of its own at a steady 120Hz, which is what a trackpad on this
        // machine delivers. Pacing from the main thread would mean the drag slowed down exactly
        // when the main thread got busy, which is the thing being measured.
        let done = Mutex(false)
        let pid = ProcessInfo.processInfo.processIdentifier
        Thread.detachNewThread {
            post(.leftMouseDown, at: flipped, pid: pid)
            Thread.sleep(forTimeInterval: 0.05)
            for offset in sequence {
                let point = CGPoint(x: flipped.x + offset, y: flipped.y)
                post(.leftMouseDragged, at: point, pid: pid)
                Thread.sleep(forTimeInterval: 1.0 / 120.0)
            }
            post(.leftMouseUp, at: CGPoint(x: flipped.x, y: flipped.y), pid: pid)
            done.withLock { $0 = true }
        }

        // Waited on by yielding the main thread rather than blocking it: the tracking loop that
        // consumes these events IS the main thread.
        while !done.withLock({ $0 }) {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(4))
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    private nonisolated static func post(_ type: CGEventType, at point: CGPoint, pid: pid_t) {
        guard let event = CGEvent(
            mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left
        ) else { return }
        event.postToPid(pid)
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

    private static func report(
        recorder: FrameRecorder, window: NSWindow, split: NSSplitView
    ) -> [String: Any] {
        let intervals = recorder.intervals.map { $0 * 1000 }
        let sorted = intervals.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
            return sorted[index]
        }
        let total = intervals.reduce(0, +)
        let mean = intervals.isEmpty ? 0 : total / Double(intervals.count)
        let refresh = Double(window.screen?.maximumFramesPerSecond ?? 60)

        return [
            "driver": driver,
            "selection": selection ?? "home",
            // What the window is ACTUALLY showing, rather than what was asked for. `AppModel`
            // reselects the last workspace on launch, so a run that meant to measure Home
            // silently measured a workspace as soon as any earlier run had opened one, and the
            // two configurations converged on the same number for a reason that had nothing to do
            // with either of them.
            "inspector": wantsInspector,
            "bottomPanel": wantsBottomPanel,
            "restoredWorkspace":
                UserDefaults.standard.string(forKey: "sidebar.lastWorkspaceID") ?? "none",
            "configuration": buildConfiguration,
            "displayHz": refresh,
            "frames": intervals.count,
            "durationMs": total,
            "meanMs": mean,
            "meanFps": mean > 0 ? 1000 / mean : 0,
            "medianMs": percentile(0.5),
            "medianFps": percentile(0.5) > 0 ? 1000 / percentile(0.5) : 0,
            "p95Ms": percentile(0.95),
            "p99Ms": percentile(0.99),
            "maxMs": sorted.last ?? 0,
            "framesOver16ms": intervals.filter { $0 > 16.7 }.count,
            "framesOver33ms": intervals.filter { $0 > 33.4 }.count,
            "sidebarWidth": split.arrangedSubviews[0].frame.width,
            // Proof the drag landed. A run whose min and max are the same measured nothing.
            "sidebarWidthMin": recorder.widths.min() ?? 0,
            "sidebarWidthMax": recorder.widths.max() ?? 0,
            "sidebarWidthSteps": Set(recorder.widths).count,
            "windowSize": ["w": window.frame.width, "h": window.frame.height],
            "dragSteps": sweepOffsets(sweeps: sweeps).count,
            "mainThreadCpuMs": mainThreadCPU * 1000,
            "wallMs": wallClock * 1000,
            "mainThreadBusyFraction": wallClock > 0 ? mainThreadCPU / wallClock : 0,
            "cpuMsPerStep": mainThreadCPU * 1000 / Double(max(1, sweepOffsets(sweeps: sweeps).count)),
            "loadAverage": systemLoadAverage(),
            "paneLayout": PaneLayoutTiming.summary(),
            "histogramMs": intervals,
        ]
    }

    /// How much CPU the main thread actually burned, and over how long.
    ///
    /// Recorded because a wall clock frame interval is a measurement of this machine as well as of
    /// this app, and this machine has other agents building on it. CPU time per drag step barely
    /// moves when the load average does, so it is the number two builds can be compared with;
    /// the frame interval is the number that says what the drag feels like.
    private static var mainThreadCPU: Double = 0
    private static var wallClock: Double = 0

    private static func mainThreadCPUSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000_000
    }

    private static var buildConfiguration: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    /// Recorded with every run, so a number taken while three other builds were running can be
    /// recognised as one rather than believed.
    private static func systemLoadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) > 0 else { return 0 }
        return loads[0]
    }

    private static func write(_ report: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]))
            ?? Data()
        try? data.write(to: URL(fileURLWithPath: outputPath))
        FileHandle.standardError.write(Data("frame probe wrote \(outputPath)\n".utf8))
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("frame probe: \(message)\n".utf8))
        exit(1)
    }
}

/// Records when the main thread was free, once per vsync.
///
/// `CADisplayLink` rather than a timer, because a timer fires in whatever mode it was scheduled
/// for and a divider drag runs in `NSEventTrackingRunLoopMode`. Added to the common modes for the
/// same reason.
@MainActor
private final class FrameRecorder {
    private var link: CADisplayLink?
    private let view: NSView
    /// The width the probe is supposed to be moving. Sampled once a frame so a run that measured
    /// a perfectly idle window can be told apart from a run whose synthetic drag never landed.
    private let observe: () -> CGFloat
    private var last: CFTimeInterval = 0
    private(set) var intervals: [Double] = []
    private(set) var widths: [CGFloat] = []
    private var isRecording = false

    init(view: NSView, observe: @escaping () -> CGFloat) {
        self.view = view
        self.observe = observe
    }

    func start() {
        intervals.removeAll()
        widths.removeAll()
        last = 0
        isRecording = true
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        isRecording = false
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        guard isRecording else { return }
        let now = CACurrentMediaTime()
        widths.append(observe())
        defer { last = now }
        guard last != 0 else { return }
        intervals.append(now - last)
    }
}
