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
/// the display link and the frame timings, because "how long did a frame take" is the same
/// question however the window was made to move.
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
///
/// Everything that is not the arrangement and the drag is `ProbeHarness`: the flags, the window,
/// the model, the failure, the frame timings, the report.
@MainActor
enum ResizeProbe {
    private static let harness = ProbeHarness(subject: "resize")

    static var isRequested: Bool { harness.isRequested }

    // MARK: - Arguments

    private static var workspaceID: WorkspaceID? {
        ProbeHarness.value(for: "--resize-workspace").map(WorkspaceID.init)
    }

    private static var sweeps: Int { ProbeHarness.count("--resize-sweeps", or: 4) }
    private static var travel: CGFloat { ProbeHarness.points("--resize-travel", or: 240) }
    private static var step: CGFloat { ProbeHarness.points("--resize-step", or: 4) }

    /// Where the browser pane goes. A file URL by preference, and empty by default: a run that has
    /// to reach the network is a run that measures the network.
    private static var pageURL: String { ProbeHarness.text("--resize-url", or: "") }

    /// What is in the centre column. `chat+browser` is the complaint; `chat` is the control that
    /// says how much of the cost the second pane is, which is the number the question "should a
    /// hidden pane be kept alive across a tab switch" turns on. A pane kept alive is a pane laid
    /// out on every frame of every resize, and the only way to price that is to measure a window
    /// with one more pane in it than it needs.
    private static var arrangement: String {
        ProbeHarness.text("--resize-arrangement", or: "chat+browser")
    }

    // MARK: - Entry

    static func schedule() {
        Task { @MainActor in await run() }
    }

    private static func run() async {
        // Never brought to the front, for the reason at the head of `ProbeHarness.window`.
        let (window, contentView) = await harness.window()

        guard let app = ProbeHarness.appModel else { harness.fail("no app model") }
        guard let workspaceID else { harness.fail("--resize-workspace named no workspace") }
        app.selection = .workspace(workspaceID)
        app.isInspectorVisible = true

        // The workspace's own arrival, which this probe is not measuring: its sessions, its
        // transcript, `git status` and the first diff all land in here rather than in a frame.
        try? await Task.sleep(for: .seconds(8))

        guard let workspace = app.existingModel(for: workspaceID) else {
            harness.fail("workspace \(workspaceID.rawValue) is not open")
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

        harness.markStarted()

        PaneLayoutTiming.reset()
        PaneLayoutTiming.isEnabled = true
        TranscriptHoldCensus.reset()
        recorder.start()
        let cpuBefore = ProbeHarness.mainThreadCPUSeconds()
        let wallBefore = CACurrentMediaTime()
        await drag(window, sweeps: sweeps)
        let cpu = ProbeHarness.mainThreadCPUSeconds() - cpuBefore
        let wall = CACurrentMediaTime() - wallBefore
        recorder.stop()
        PaneLayoutTiming.isEnabled = false

        harness.write(report(
            recorder: recorder, window: window, workspace: workspace, cpu: cpu, wall: wall
        ))
        exit(0)
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
            harness.fail("the workspace has no conversation to put beside a browser")
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
    ) -> JSONValue {
        let widths = recorder.widths
        let tabs = WorkspaceTabsStore.shared
        let panes = tabs.selectedTab(in: workspace).map { tabs.layout(of: $0).paneCount } ?? 0
        let steps = offsets(sweeps: sweeps).count

        let own: [String: JSONValue] = [
            "driver": .string("programmatic"),
            "arrangement": .string(arrangement),
            "workspace": .string(workspace.workspace.id.rawValue),
            "workspaceName": .string(workspace.workspace.name),
            "drawnRows": .integer(TranscriptDrawn.rows),
            "sessionRows": .integer(workspace.activeTranscript?.rows.count ?? 0),
            // The three claims the timings below are worthless without. See the head of this file.
            "panes": .integer(panes),
            "inspector": .bool(AppModel.probeInstance?.isInspectorVisible ?? false),
            "changedFiles": .integer(workspace.changedFiles.count),
            // Proof the drag landed. A run whose min and max agree resized nothing.
            "widthMin": .number(Double(widths.min() ?? 0)),
            "widthMax": .number(Double(widths.max() ?? 0)),
            "widthSteps": .integer(Set(widths).count),
            "didResize": .bool((widths.max() ?? 0) - (widths.min() ?? 0) > 1),
            "steps": .integer(steps),
            "travel": .number(Double(travel)),
            "step": .number(Double(step)),
            "sweeps": .integer(sweeps),
            // What two builds are compared with, for `FrameProbe`'s reason: a wall clock frame
            // interval measures this machine as well as this app, and CPU per step does not.
            "mainThreadCpuMs": .number(cpu * 1000),
            "wallMs": .number(wall * 1000),
            "mainThreadBusyFraction": .number(wall > 0 ? cpu / wall : 0),
            "cpuMsPerStep": .number(cpu * 1000 / Double(max(1, steps))),
            "paneLayout": .map(PaneLayoutTiming.summary()),
            // Whether the transcript actually held still, and how many rows it did not have to
            // measure when it let go. See `TranscriptHoldCensus`.
            "transcriptHold": .map(TranscriptHoldCensus.summary()),
        ]
        // The probe's own keys win over both, so a report that has an opinion keeps it.
        return .object(
            own
                .merging(ProbeHarness.frameTimings(recorder.intervals.map { $0 * 1000 })) { mine, _ in mine }
                .merging(harness.conditions(window: window)) { mine, _ in mine }
        )
    }
}
