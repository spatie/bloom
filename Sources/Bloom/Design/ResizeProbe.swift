import AppKit
import SwiftUI
import QuartzCore
import BloomCore

/// Measures what a window resize costs when the window is full: a conversation, a browser and the
/// changed files, all on screen at once.
///
/// The fifth of the family, after `FrameProbe` (a divider drag), `SwitchProbe` (a workspace),
/// `TabProbe` (a tab) and `ScrollProbe` (a transcript). It exists because the owner's third
/// complaint is about a gesture none of the four could produce. `FrameProbe --probe-gesture
/// window` resizes a window, and `--probe-pane browser` opens a browser, but opening a tab SELECTS
/// it, so what that run measured was a window with one thing in it. The complaint is specifically
/// about three: "resizing the app is also not smooth when there is a chat, a browser and a change
/// list displayed at the same time".
///
/// So the whole of what this adds is the arrangement. It splits the conversation's tab so the chat
/// and a browser share the centre column, leaves the inspector showing the worktree's changed
/// files, and only then drags the window's own edge. Everything else is `FrameProbe`'s, down to
/// the display link and the two drivers, because "how long did a frame take" is the same question
/// however the window was made to move.
///
/// **Programmatic, and deliberately without a mouse driver.** `FrameProbe` has one and needs it:
/// AppKit's live resize path sets `inLiveResize`, throttles and coalesces, and a faithful answer
/// about a hand needs all of it. It also needs the window in front and the app activated, which is
/// the owner's keyboard taken. This probe is the one that gets run over and over between two
/// builds, so it takes the deterministic driver only. What it loses is the live resize path; what
/// it measures instead is the layout the window owes per point of width, which is the part a
/// faster build makes faster.
///
///     Bloom --resize-probe /tmp/resize.json --resize-workspace <id>
///           [--resize-sweeps 4] [--resize-travel 240] [--resize-step 4]
///           [--resize-url file:///…] [--window-size 1440x900]
///
/// A sweep narrows the window by `travel` points and widens it back, `step` points per vsync. Four
/// points at 120Hz is 480 points a second, which is a firm drag rather than a flick.
///
/// The report says what was actually on screen as well as what each frame cost, for the reason
/// every probe here has learned the hard way: a run that measured a window with one pane in it,
/// or with no changed files to list, is a run whose number means something else. `panes`,
/// `inspector` and `changedFiles` are the three that have to be believed before the timings are.
@MainActor
enum ResizeProbe {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--resize-probe")
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
        value(for: "--resize-probe") ?? (NSTemporaryDirectory() + "bloom-resize-probe.json")
    }

    private static var workspaceID: WorkspaceID? {
        value(for: "--resize-workspace").map(WorkspaceID.init)
    }

    private static var sweeps: Int { Int(value(for: "--resize-sweeps") ?? "") ?? 4 }
    private static var travel: CGFloat { CGFloat(Double(value(for: "--resize-travel") ?? "") ?? 240) }
    private static var step: CGFloat { CGFloat(Double(value(for: "--resize-step") ?? "") ?? 4) }

    /// Where the browser pane goes. A file URL by preference, and empty by default: a run that has
    /// to reach the network is a run that measures the network.
    private static var pageURL: String { value(for: "--resize-url") ?? "" }

    /// What is in the centre column. `chat+browser` is the complaint; `chat` is the control that
    /// says how much of the cost the second pane is, which is the number the question "should a
    /// hidden pane be kept alive across a tab switch" turns on. A pane kept alive is a pane laid
    /// out on every frame of every resize, and the only way to price that is to measure a window
    /// with one more pane in it than it needs.
    private static var arrangement: String { value(for: "--resize-arrangement") ?? "chat+browser" }

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
        // Never brought to the front, for the reason at the head of `FrameProbe`.
        try? await Task.sleep(for: .seconds(3))

        guard let window = await firstWindow(), let contentView = window.contentView else {
            fail("no window to probe")
        }

        if let size = windowSize {
            window.setContentSize(size)
            window.layoutIfNeeded()
            try? await Task.sleep(for: .seconds(1))
        }

        guard let app = model() else { fail("no app model") }
        guard let workspaceID else { fail("--resize-workspace named no workspace") }
        app.selection = .workspace(workspaceID)
        app.isInspectorVisible = true

        // The workspace's own arrival, which this probe is not measuring: its sessions, its
        // transcript, `git status` and the first diff all land in here rather than in a frame.
        try? await Task.sleep(for: .seconds(8))

        guard let workspace = app.existingModel(for: workspaceID) else {
            fail("workspace \(workspaceID.rawValue) is not open")
        }

        await arrange(workspace)

        // The page has to load and the transcript has to settle. Longer than any of the other
        // probes wait, because this is the only one that asks for three things at once.
        try? await Task.sleep(for: .seconds(8))

        let recorder = FrameRecorder(view: contentView) { [weak window] in
            window?.frame.width ?? 0
        }

        // A warm pass that is thrown away. The first resize of a launch pays for every layout
        // cache the window has not built yet, and reporting that as the steady state would
        // overstate every number. `ScrollProbe` and `FrameProbe` both do this and for this reason.
        await drag(window, sweeps: 1)
        try? await Task.sleep(for: .seconds(1))

        // A marker on disk rather than a line on stderr, so a shell watching for it can start
        // `sample` at the moment the measured drag begins rather than profiling twenty seconds of
        // a window loading a conversation. Copied from `FrameProbe` for the same reason.
        try? Data("\(ProcessInfo.processInfo.processIdentifier)".utf8)
            .write(to: URL(fileURLWithPath: outputPath + ".started"))

        PaneLayoutTiming.reset()
        PaneLayoutTiming.isEnabled = true
        recorder.start()
        let cpuBefore = mainThreadCPUSeconds()
        let wallBefore = CACurrentMediaTime()
        await drag(window, sweeps: sweeps)
        let cpu = mainThreadCPUSeconds() - cpuBefore
        let wall = CACurrentMediaTime() - wallBefore
        recorder.stop()
        PaneLayoutTiming.isEnabled = false

        write(report(
            recorder: recorder, window: window, workspace: workspace, cpu: cpu, wall: wall
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

    // MARK: - The arrangement

    /// Puts a browser beside the conversation, in the same tab, so both are on screen at once.
    ///
    /// A split rather than a second tab, because a tab is the thing that is NOT on screen. The
    /// chat is selected first so the split is made from it whatever the window was last left
    /// showing, and the browser goes in the half that opens.
    ///
    /// **The tab is collapsed to one pane before it is split.** A split arrangement is persisted in
    /// the preferences domain, so a second run against the same domain inherits the first run's
    /// split and adds another: measured, four panes on the second run and six on the third, and
    /// the two numbers were compared as though they were the same window. A probe has to start
    /// from a known arrangement or it is not measuring the same thing twice.
    private static func arrange(_ workspace: WorkspaceModel) async {
        let tabs = WorkspaceTabsStore.shared
        guard let chat = tabs.entries(in: workspace).first(where: { $0.isChat }) else {
            fail("the workspace has no conversation to put beside a browser")
        }
        tabs.select(chat, in: workspace)

        // Bounded rather than `while`, so a `close` that ever stops making progress ends the run
        // with a report instead of spinning the main actor for ever.
        for _ in 0..<16 {
            let layout = tabs.layout(of: chat)
            guard layout.paneCount > 1, let pane = layout.panes.last else { break }
            guard tabs.close(pane: pane, in: chat, of: workspace.workspace.id) else { break }
        }
        try? await Task.sleep(for: .seconds(2))

        guard arrangement != "chat" else { return }
        NewPane.open(.browser, in: workspace, url: pageURL) { content in
            tabs.split(tab: chat, axis: .horizontal, showing: content)
        }
    }

    // MARK: - Driving

    /// Narrows the window by `travel` and widens it back, `sweeps` times.
    ///
    /// The frame is set rather than the content size, and the top left corner is held still, so
    /// this is the geometry a hand dragging the bottom right corner produces: the title bar does
    /// not move and the window grows to the right.
    ///
    /// `display: true` is what makes a step cost what a frame of a drag costs. Without it AppKit
    /// is free to defer the layout and a hundred steps collapse into one. `FrameProbe` records
    /// the same finding.
    private static func drag(_ window: NSWindow, sweeps: Int) async {
        let start = window.frame
        for offset in offsets(sweeps: sweeps) {
            var frame = start
            frame.size.width = start.width + offset
            window.setFrame(frame, display: true)
            try? await Task.sleep(for: .microseconds(8_333))
        }
        window.setFrame(start, display: true)
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// A triangle wave, inwards from wherever the window starts.
    ///
    /// Inwards for `FrameProbe`'s reason: a sweep that grows the window runs into the screen and
    /// spends most of its steps parked against an edge, where nothing re-lays out and the probe
    /// reports a frame rate for a window standing still.
    private static func offsets(sweeps: Int) -> [CGFloat] {
        var offsets: [CGFloat] = []
        for _ in 0..<sweeps {
            var x: CGFloat = 0
            while x > -travel { offsets.append(x); x -= step }
            while x < 0 { offsets.append(x); x += step }
        }
        return offsets
    }

    // MARK: - Reporting

    private static func report(
        recorder: FrameRecorder, window: NSWindow, workspace: WorkspaceModel,
        cpu: Double, wall: Double
    ) -> [String: Any] {
        let ms = recorder.intervals.map { $0 * 1000 }.sorted()
        func percentile(_ p: Double) -> Double {
            guard !ms.isEmpty else { return 0 }
            let index = Int((Double(ms.count - 1) * p).rounded())
            return ms[min(max(index, 0), ms.count - 1)]
        }
        // A frame that took longer than two vsyncs, measured against this run's own median rather
        // than against a fixed 16.7. See `ScrollProbe`, which explains why a 120Hz panel and a
        // 60Hz one cannot share a threshold.
        let refresh = ms.isEmpty ? 8.3 : percentile(0.5)
        let dropped = ms.filter { $0 > refresh * 1.8 }.count
        let widths = recorder.widths
        let tabs = WorkspaceTabsStore.shared
        let panes = tabs.selectedTab(in: workspace).map { tabs.layout(of: $0).paneCount } ?? 0

        return [
            "driver": "programmatic",
            "arrangement": arrangement,
            "configuration": buildConfiguration,
            "workspace": workspace.workspace.id.rawValue,
            "workspaceName": workspace.workspace.name,
            "sessionRows": workspace.activeTranscript?.rows.count ?? 0,
            // The three claims the timings below are worthless without. See the head of this file.
            "panes": panes,
            "inspector": AppModel.probeInstance?.isInspectorVisible ?? false,
            "changedFiles": workspace.changedFiles.count,
            "frames": ms.count,
            "medianMs": percentile(0.5),
            "medianFps": percentile(0.5) > 0 ? 1000 / percentile(0.5) : 0,
            "p95Ms": percentile(0.95),
            "p99Ms": percentile(0.99),
            "worstMs": ms.last ?? 0,
            "droppedFrames": dropped,
            "droppedShare": ms.isEmpty ? 0 : Double(dropped) / Double(ms.count),
            // Proof the drag landed. A run whose min and max agree resized nothing.
            "widthMin": widths.min() ?? 0,
            "widthMax": widths.max() ?? 0,
            "widthSteps": Set(widths).count,
            "didResize": (widths.max() ?? 0) - (widths.min() ?? 0) > 1,
            "windowSize": ["w": window.frame.width, "h": window.frame.height],
            "steps": offsets(sweeps: sweeps).count,
            "travel": travel,
            "step": step,
            "sweeps": sweeps,
            // What two builds are compared with, for `FrameProbe`'s reason: a wall clock frame
            // interval measures this machine as well as this app, and CPU per step does not.
            "mainThreadCpuMs": cpu * 1000,
            "wallMs": wall * 1000,
            "mainThreadBusyFraction": wall > 0 ? cpu / wall : 0,
            "cpuMsPerStep": cpu * 1000 / Double(max(1, offsets(sweeps: sweeps).count)),
            "loadAverage": systemLoadAverage(),
            "paneLayout": PaneLayoutTiming.summary(),
        ]
    }

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

    private static func systemLoadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) > 0 else { return 0 }
        return loads[0]
    }

    // MARK: - Reaching the model

    /// The app's state, handed over by the delegate on launch. Weak, for the reason `SwitchProbe`
    /// gives: a probe has no business keeping the app alive.
    private static func model() -> AppModel? { AppModel.probeInstance }

    private static func write(_ report: [String: Any]) {
        // Asked before the encode, for the reason `SwitchProbe.write` records: a typed id in a
        // `[String: Any]` arrives as `__SwiftValue`, and `JSONSerialization` raises rather than
        // throwing, which `try?` does not catch and which killed a run on its last line.
        guard JSONSerialization.isValidJSONObject(report) else {
            fail("the report holds a value JSON cannot carry, probably an id that needed .rawValue")
        }
        let data = (try? JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys]
        )) ?? Data()
        try? data.write(to: URL(fileURLWithPath: outputPath))
        FileHandle.standardError.write(Data("resize probe wrote \(outputPath)\n".utf8))
    }

    /// `Never`, so the callers above can end a run with it from inside a `guard`.
    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("resize probe: \(message)\n".utf8))
        exit(1)
    }
}
