import AppKit
import SwiftUI
import QuartzCore
import BloomCore

/// **Watches the transcript go blank when the composer divider is dragged.**
///
/// The eighth of the family, and the first written to catch a bug rather than to time a gesture.
/// What it produces is a row by row table of what the height cache and the table each believe,
/// taken before the drag, after it, after a scroll and after a window resize, plus a light sample
/// per step of the drag. The question is not what the drag cost. It is which rows stopped being
/// drawn and which frame stopped them.
///
/// **Why it exists.** Dragging the composer taller empties the transcript. It has been diagnosed
/// twice by reading and shipped once, as a placement resolved against a pane of no height
/// (`TranscriptAnchor.canPlace`, PR 136), and the owner reproduced it again on 1.1.0 with that fix
/// in. What he then described rules the placement theory out on its own: he scrolled up and saw
/// some content but not all, scrolled back down and saw only the final line with the middle
/// missing, and after scrolling about a while got all of it back. A viewport parked below the last
/// row shows nothing at all and then shows everything. Rows appearing one at a time is rows drawn
/// at no height, individually.
///
/// **So what this is looking for is a silence.** `TranscriptRowHeights.note` records a measured
/// nought as an answer. `measuredNothing` then refuses the row a view for ever, `needsMeasuring`
/// refuses to measure it again, and `isGuessed` does not even count it, because the cache and the
/// table agree perfectly about nothing. One bad measurement while the pane is mid drag is a row
/// the reader has lost until something marks the key stale, and the only thing that marks every
/// key stale is a width change. That is exactly the shape of "dragging the window edge brings it
/// back", which the owner confirmed.
///
/// **And a second theory the owner's own recording argues for instead, which is why the report
/// carries both.** In the video the transcript comes back by SCROLLING, with no window resize:
/// blank, then a screen of rows, then the last line with the middle missing, then all of it.
/// `repairTheScreen` measures a screenful on every settle, and `measureExactly` skips any key the
/// cache already knows, so a row recorded at nought could not be repaired that way. A row the
/// cache holds NOTHING for could. So the shape that fits the video is the measured heights being
/// LOST rather than one row being silenced: `forget` and `reset` empty the lot, every row is then
/// answered from the mean, the document is the wrong length, and the reader is left looking at
/// part of it until each screen is measured again.
///
/// `cached` and `cacheWidth` are the two columns that tell those apart, per step of the drag. A
/// step where `cached` falls to nothing emptied the cache; `cacheWidth` beside it says whether a
/// width did it, which matters because `Coordinator.columnWidth` answers the TABLE's width and
/// falls back to the clip view's, and with legacy scrollers those two differ by fifteen points.
///
/// The four phases are what those theories predict, so a run can falsify either:
///
/// - `afterTaller`: rows with `known` nought and `drawsNothing` false, `hasCell` false, and
///   `silencedRows` above nought, if rows are being silenced. `cached` at nothing, and rows with
///   `known` nil, if the cache is being emptied instead.
/// - `afterScrolling`: a silenced row is still silenced and a merely unmeasured one is not, so
///   this phase is what separates them.
/// - `afterWindowResize`: everything measured again either way, because `rewidth` marks every key
///   stale. A run where even this does not repair it says both theories are wrong.
///
/// # What the first run said, which was neither of them
///
/// **Both theories died and the bug was in the report anyway.** Against the owner's own
/// conversation, 20,357 messages and 14,322 drawn rows: two lost rows before the drag and two
/// after, so nothing was silenced; `cached` rose monotonically and `cacheWidth` never moved, so
/// nothing was emptied. `reproduced` said false because it was asking about silences.
///
/// What the steps showed instead is the document's own length. 229,351 points at step 0, 885,212
/// by step 13, 171,535 at step 14. The same 2,650 rows throughout, and nine new measurements
/// across the thirteen steps that quadrupled it. The rows above the band, 2,242 of them and not
/// one measured, were given 75 points each before the drag, 367 during it and 65 after the window
/// resize: the region above the reader grew by 656,000 points and then collapsed by 678,000,
/// while nothing about those rows changed.
///
/// That is `TranscriptRowHeights.estimate(for:)`, and the row tables say why. Of 408 rows in the
/// band, 26 had ever been measured at more than nothing; their mean was 651 points and their
/// largest was 10,806. `settleShapeAfter` is three, so three samples settle a shape's number for
/// every unmeasured row of it, and one huge answer in a sample of five is what handed 54
/// unmeasured `answer` rows 347 points each, three `message` rows 418, and, before it re-settled,
/// four rows 6,025 points each. A viewport of 446 points inside rows drawn six thousand points
/// tall is a blank pane, and a reader scrolling through them measures them one screen at a time,
/// which is the recovery the owner filmed.
///
/// So `reproduced` asks about the length now. The silence keys stay because they are cheap and
/// because the run that shows both is worth more than the run that shows either.
///
/// **The driver is the stored height rather than a synthetic hand**, for `ResizeProbe`'s reason: a
/// mouse driver needs this app in front and takes the owner's keyboard. `ComposerView` reads
/// `composer.editorHeight` out of the defaults domain through `@AppStorage`, so stepping it once
/// per vsync moves the editor exactly as the end of a real drag does, one step at a time, and
/// reproduces the thing the last diagnosis turned on: the editor's height moves a pass before the
/// composer holding it is laid out, so `ComposerView.chromeHeight` is measured from a total a
/// frame behind and `PaneMeasure.editorCap` is computed from a chrome that is short. What it does
/// not reproduce is `liveHeight`, which is the same arithmetic through a different property.
///
/// It writes to the DEV defaults domain, which is what `make dev` gives this build, and it puts
/// the key back where it found it. A run that inherits the last run's composer height is the
/// mistake `ResizeProbe.arrange` learned about splits.
///
///     Bloom --composer-probe /tmp/composer.json --composer-workspace <id>
///           [--composer-pane-width 640] [--composer-arrangement chat|chat+browser]
///           [--composer-url file:///…] [--composer-travel 320] [--composer-step 24]
///           [--composer-settle 1200] [--composer-band 400]
///           [--window-size 1440x900] [--window-hidden]
///
/// **A run states its pane width before anything else and refuses to run at another one.** Two
/// batches of this probe were compared against each other before anybody noticed they had measured
/// panes 420 and 747 points wide, on the same window size and the same arrangement, because the
/// divider position is autosaved into the defaults domain. Width decides every row height there
/// is, so those runs were never comparable. See `paneWidth` and `pin`.
///
/// The per-step sample reads six numbers and one `rows(in:)` and walks nothing: see the head of
/// `ProbeHarness` for the run that was read as a regression in the app because its census grew
/// with what it was watching. The row tables do walk, and they are taken four times, each while
/// the pane is standing still.
@MainActor
enum ComposerProbe {
    private static let harness = ProbeHarness(subject: "composer")

    static var isRequested: Bool { harness.isRequested }

    /// The key `ComposerView.manualHeight` is stored under. Spelled here rather than reached for,
    /// because a probe driving a key the view had stopped reading would report a clean run.
    private static let heightKey = "composer.editorHeight"

    // MARK: - Arguments

    private static var workspaceID: WorkspaceID? {
        ProbeHarness.value(for: "--composer-workspace").map(WorkspaceID.init)
    }

    /// How much taller the editor is dragged, in points, and how much of that lands per vsync.
    /// The default step is a line and a half, which is a firm drag rather than a flick: the
    /// suspicion is that the hand outruns the layout, so a step that cannot is no test.
    private static var travel: CGFloat { ProbeHarness.points("--composer-travel", or: 320) }
    private static var step: CGFloat { ProbeHarness.points("--composer-step", or: 24) }

    /// How long the pane is left alone before a row table is taken. Everything in
    /// `TranscriptTable` that would repair a row runs on a settle or a turn later, so a dump taken
    /// too early reports a state the app was about to leave.
    private static var settleMs: Int { ProbeHarness.count("--composer-settle", or: 1200) }

    /// How many rows either side of the visible ones the row table covers. Wider than the screen
    /// on purpose: a row silenced while the pane was short is one the reader scrolls back to
    /// rather than one they are looking at.
    private static var band: Int { ProbeHarness.count("--composer-band", or: 400) }

    /// **The width the transcript pane is put at before anything is measured.**
    ///
    /// A run that does not state this is a run that cannot be compared with another, and two
    /// batches were spent finding that out. The pane came out 420 points wide in one batch and 747
    /// in the next, on the same window size and the same arrangement, because
    /// `DetailSplitViewController` autosaves its divider into the defaults domain and the pane is
    /// whatever the last run or the last launch left. 420 is exactly `detailMinimum`, which is the
    /// coincidence that gave it away.
    ///
    /// Width decides every row height in `TranscriptRowHeights`, so an uncontrolled width makes
    /// every absolute figure in this report incomparable. `pin` puts it where the run asks and
    /// ENDS THE RUN if it cannot, because a probe that quietly measures the wrong width is worse
    /// than no probe.
    /// **420 by default, because that is the only width the fault has ever been seen at.**
    /// It is `DetailSplitViewController.detailMinimum` exactly, which is what a 1440 window gives
    /// the centre column when the inspector is at its 760 maximum, and it is near what the owner's
    /// own layout produces with a browser pane taking half his window. At 640 the estimator this
    /// replaces behaves perfectly well: a run there proves nothing about a fix for a run here.
    private static var paneWidth: CGFloat { ProbeHarness.points("--composer-pane-width", or: 420) }

    /// The owner reproduced this with a browser beside the conversation and again with it closed,
    /// so the split is not the cause. `chat` is the default because it is the simpler window and
    /// `chat+browser` is what his screenshots show.
    private static var arrangement: String {
        ProbeHarness.text("--composer-arrangement", or: "chat")
    }

    private static var pageURL: String { ProbeHarness.text("--composer-url", or: "") }

    // MARK: - Entry

    static func schedule() {
        Task { @MainActor in await run() }
    }

    private static func run() async {
        // Never brought to the front. See the head of `ProbeHarness.window`.
        let (window, contentView) = await harness.window()

        guard let app = ProbeHarness.appModel else { harness.fail("no app model") }
        guard let workspaceID else { harness.fail("--composer-workspace named no workspace") }
        app.selection = .workspace(workspaceID)
        app.isInspectorVisible = true

        // The workspace's own arrival, which this probe is not measuring.
        try? await Task.sleep(for: .seconds(8))

        guard let workspace = app.existingModel(for: workspaceID) else {
            harness.fail("workspace \(workspaceID.rawValue) is not open")
        }
        await arrange(workspace)
        try? await Task.sleep(for: .seconds(8))

        guard let scroll = ProbeHarness.transcriptScrollView(in: contentView) else {
            harness.fail("no transcript NSScrollView found")
        }
        guard let hold = TranscriptStateDump.holdView(in: contentView) else {
            harness.fail("no TranscriptHoldView found, so this is not the transcript's pane")
        }
        let pane = TranscriptStateDump.Pane(
            scroll: scroll,
            hold: hold,
            table: scroll.documentView as? NSTableView,
            coordinator: hold.delegate as? TranscriptTable.Coordinator
        )
        guard pane.coordinator != nil else {
            harness.fail("the hold view has no coordinator, so no row facts can be read")
        }

        // **Before anything is measured**, because the width is what every row height is measured
        // against and this is the variable two batches of this probe did not control.
        await pin(window, pane: pane, in: contentView)

        // A known starting composer, so two runs are the same run. Restored at the end.
        let storedHeight = UserDefaults.standard.double(forKey: heightKey)
        UserDefaults.standard.set(0.0, forKey: heightKey)
        try? await Task.sleep(for: .seconds(1))

        // At the live end, which is where a reader dragging the composer normally is and the only
        // state in which anything places the view at all. `ResizeProbe` starts the same way.
        scroll.contentView.setBoundsOrigin(
            NSPoint(x: scroll.contentView.bounds.origin.x, y: scroll.endOffset)
        )
        scroll.reflectScrolledClipView(scroll.contentView)
        try? await Task.sleep(for: .milliseconds(400))

        TranscriptHoldCensus.reset()
        harness.markStarted()
        let before = dump(pane)

        // Taller, a step per vsync, which is the direction the bug is reported in. Kept apart
        // from the drag back down, because everything between them exists to remeasure and a
        // verdict taken over both would be a verdict about the probe's own phases. See `report`.
        let drag = await drive(from: 0, to: travel, by: step, pane: pane)
        try? await Task.sleep(for: .milliseconds(settleMs))
        let afterTaller = dump(pane)

        // **Scrolling, because he says it brings some of it back.** A row that was merely
        // unmeasured is put right by `repairTheScreen` on the settle. A row recorded at nought is
        // not, and the difference between these two tables is the whole hypothesis.
        await scrollAbout(pane)
        try? await Task.sleep(for: .milliseconds(settleMs))
        let afterScrolling = dump(pane)

        // **And the window edge, because he says that fixes it.** A width change is the one thing
        // that marks every key stale, so if the rows come back here they were silenced rather than
        // misplaced.
        await nudgeWindowWidth(window)
        try? await Task.sleep(for: .milliseconds(settleMs))
        let afterWindowResize = dump(pane)

        // And back down, so the run leaves the composer where it found it as well as the key.
        let dragBack = await drive(from: travel, to: 0, by: -step, pane: pane)
        UserDefaults.standard.set(storedHeight, forKey: heightKey)

        harness.write(report(
            window: window,
            pane: pane,
            workspace: workspace,
            before: before,
            afterTaller: afterTaller,
            afterScrolling: afterScrolling,
            afterWindowResize: afterWindowResize,
            drag: drag,
            dragBack: dragBack
        ), echo: false)
        exit(0)
    }

    // MARK: - The arrangement

    /// A browser beside the conversation, in the same tab, when the run asks for one.
    ///
    /// `ResizeProbe.arrange`'s, including the collapse to one pane first: a split is persisted in
    /// the defaults domain, so a second run against the same domain inherits the first run's split
    /// and adds another. Four panes on the second run and six on the third, compared as though
    /// they were the same window.
    private static func arrange(_ workspace: WorkspaceModel) async {
        let tabs = WorkspaceTabsStore.shared
        guard let chat = tabs.entries(in: workspace).first(where: { $0.isChat }) else {
            harness.fail("the workspace has no conversation to drag a composer in")
        }
        tabs.select(chat, in: workspace)

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

    // MARK: - Pinning the width

    /// **Puts the transcript pane at the width the run asked for, or ends the run.**
    ///
    /// **The divider is the lever, not the window, and the first spelling of this had it wrong.**
    /// Growing the window looked right, because the centre column holds at `defaultLow` and is the
    /// item that absorbs a resize. It cannot reach the widths that matter: the pane cannot go below
    /// `DetailSplitViewController.detailMinimum` however small the window gets, the window has a
    /// minimum of its own that it hits first, and a run asking for 640 refused at a pane of 810 in
    /// a window of 1,122. What makes the pane narrow is a WIDE INSPECTOR, which is why batch 24
    /// landed on exactly 420: the inspector was at its 760 maximum and 1440 less 760 less a 260
    /// sidebar is the centre column's floor.
    ///
    /// So the window is set first, because `--window-size` is applied before `arrange` and the
    /// arrangement moves it afterwards, and because the dev app's saved window state lives in its
    /// own preferences domain and survives a reinstall, so two runs asking for 1440x900 reached
    /// 1,333 and 1,122. Then the divider is driven until the pane is where the run asked.
    ///
    /// A hard failure at the end, naming every width involved, because the whole reason this
    /// exists is that two batches of runs measured panes nobody had stated.
    private static func pin(_ window: NSWindow, pane: TranscriptStateDump.Pane, in root: NSView) async {
        if let raw = ProbeHarness.value(for: "--window-size"),
           let size = ProbeStats.windowSize(raw) {
            window.setContentSize(size)
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let split = detailSplitView(in: root) else {
            harness.fail("no split view holds the transcript, so its width cannot be pinned")
        }
        // **Both levers, in that order.** The divider is the one that matters, because a wide
        // inspector is what makes the pane narrow. It runs out: the inspector has a maximum of 760
        // and the sidebar takes what it takes, so at some window widths the centre column cannot
        // be squeezed to the target however the divider is set. A pass that moves the divider and
        // finds the pane exactly where it was is that limit, and the window is what is left to
        // move.
        for _ in 0..<12 {
            let current = pane.hold.bounds.width
            guard abs(current - paneWidth) > 1 else { return }
            let column = split.arrangedSubviews[0].frame.width
            split.setPosition(column + (paneWidth - current), ofDividerAt: 0)
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(250))
            guard abs(pane.hold.bounds.width - current) < 1 else { continue }
            var frame = window.frame
            frame.size.width += paneWidth - pane.hold.bounds.width
            window.setFrame(frame, display: true)
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(250))
        }
        let widths = split.arrangedSubviews.map { Int($0.frame.width) }
        harness.fail(
            "the transcript pane is \(Int(pane.hold.bounds.width)) points wide and the run asked "
                + "for \(Int(paneWidth)). The window is \(Int(window.frame.width)) and the split "
                + "is \(widths). Nothing measured at another width is comparable, so this run is "
                + "refused."
        )
    }

    /// The split view whose FIRST arranged half holds the transcript, which is
    /// `DetailSplitViewController`'s and not the window's own.
    ///
    /// The deepest match, because the transcript is inside both: the window's split has the
    /// sidebar beside the whole detail half, and this one has the centre column beside the
    /// inspector. Two arranged subviews, because that is what the detail split has and the sidebar
    /// one may not.
    private static func detailSplitView(in root: NSView) -> NSSplitView? {
        var best: (view: NSSplitView, depth: Int)?
        func walk(_ view: NSView, _ depth: Int) {
            if let split = view as? NSSplitView, split.arrangedSubviews.count == 2,
               let first = split.arrangedSubviews.first, TranscriptStateDump.holdView(in: first) != nil {
                if best == nil || depth > (best?.depth ?? 0) { best = (split, depth) }
            }
            for subview in view.subviews { walk(subview, depth + 1) }
        }
        walk(root, 0)
        return best?.view
    }

    // MARK: - Driving

    /// Steps the stored editor height from one value to another, sampling the pane on each step.
    ///
    /// A sleep between steps rather than a display link, for `ResizeProbe`'s reason: the point is
    /// that each step is laid out before the next arrives, which is what a hand produces, and a
    /// step whose layout AppKit is free to coalesce measures a drag that never happened.
    private static func drive(
        from start: CGFloat,
        to finish: CGFloat,
        by step: CGFloat,
        pane: TranscriptStateDump.Pane
    ) async -> [JSONValue] {
        guard step != 0 else { return [] }
        var samples: [JSONValue] = []
        var height = start
        while step > 0 ? height < finish : height > finish {
            height += step
            let clamped = step > 0 ? min(height, finish) : max(height, finish)
            UserDefaults.standard.set(Double(clamped), forKey: heightKey)
            // A layout pass, and only then the sample: what is being watched for is the pane at
            // the size this step left it, not the size the step before left it.
            pane.scroll.window?.layoutIfNeeded()
            try? await Task.sleep(for: .microseconds(8_333))
            samples.append(sample(at: clamped, pane: pane))
        }
        return samples
    }

    /// A reader looking for what went missing: up a few screens, and back down.
    ///
    /// Through `scrollWheel` rather than by writing the clip view's bounds, because a bounds write
    /// is not a scroll and none of the settle, the census or the repair is on that path. See
    /// `ProbeHarness.wheel`.
    private static func scrollAbout(_ pane: TranscriptStateDump.Pane) async {
        let screen = pane.scroll.contentView.bounds.height
        guard screen > 1 else { return }
        for _ in 0..<6 {
            ProbeHarness.wheel(pane.scroll, by: screen / 2, steps: 2)
            try? await Task.sleep(for: .milliseconds(250))
        }
        for _ in 0..<6 {
            ProbeHarness.wheel(pane.scroll, by: -screen / 2, steps: 2)
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Four points wider and back, which is the smallest thing that is still a width change.
    ///
    /// Small on purpose: the claim being tested is that a width change repairs the rows, not that
    /// a big resize does. `TranscriptRowHeights.isSameWidth` is what decides whether four points
    /// counts, and if it does not the report will show nothing changed here, which is itself the
    /// answer.
    private static func nudgeWindowWidth(_ window: NSWindow) async {
        let start = window.frame
        var wider = start
        wider.size.width = start.width + 4
        window.setFrame(wider, display: true)
        try? await Task.sleep(for: .milliseconds(600))
        window.setFrame(start, display: true)
        try? await Task.sleep(for: .milliseconds(600))
    }

    // MARK: - What a step looked like

    /// Six numbers and one `rows(in:)`, per step. Nothing here walks rows, cells or views.
    ///
    /// `silenced` is the column to read down: the step it first moves on is the frame that lost a
    /// row, and `viewportHeight` on that line is the pane it was measured against.
    private static func sample(at height: CGFloat, pane: TranscriptStateDump.Pane) -> JSONValue {
        let clip = pane.scroll.contentView
        let visible = pane.table.map { $0.rows(in: clip.documentVisibleRect).length } ?? -1
        return .object([
            "editorHeight": .number(Double(height)),
            "viewportHeight": .number(Double(clip.bounds.height)),
            "viewportWidth": .number(Double(clip.bounds.width)),
            "contentHeight": .number(Double(pane.scroll.documentView?.frame.height ?? 0)),
            "offset": .number(Double(clip.bounds.origin.y)),
            "overshoot": .number(Double(clip.bounds.origin.y - pane.scroll.endOffset)),
            "visibleRows": .integer(visible),
            "silenced": .integer(TranscriptHoldCensus.silencedRows),
            "widthMismatches": .integer(TranscriptHoldCensus.widthMismatches),
            // The number that tells an emptied cache from a missed row. See
            // `Coordinator.heightCacheCount`.
            "cached": .integer(pane.coordinator?.heightCacheCount ?? -1),
            "cacheWidth": .number(pane.coordinator?.heightCacheWidth ?? 0),
            "scrollAlpha": .number(Double(pane.scroll.alphaValue)),
            "held": .string(TranscriptStateDump.name(of: pane.hold.held)),
        ])
    }

    // MARK: - What the pane looked like

    /// Everything worth knowing about a transcript that is standing still, in one object.
    ///
    /// **`TranscriptStateDump` is where this lives**, because the app writes the same reading
    /// when a pane goes blank in ordinary use and two readings of one thing that can disagree are
    /// worth less than one that cannot. The probe asks for a wider band, because a run is read by
    /// a script and a live file is read by a person.
    private static func dump(_ pane: TranscriptStateDump.Pane) -> [String: JSONValue] {
        TranscriptStateDump.state(of: pane, band: band)
    }

    // MARK: - Reporting

    private static func report(
        window: NSWindow,
        pane: TranscriptStateDump.Pane,
        workspace: WorkspaceModel,
        before: [String: JSONValue],
        afterTaller: [String: JSONValue],
        afterScrolling: [String: JSONValue],
        afterWindowResize: [String: JSONValue],
        drag: [JSONValue],
        dragBack: [JSONValue]
    ) -> JSONValue {
        let tabs = WorkspaceTabsStore.shared
        let panes = tabs.selectedTab(in: workspace).map { tabs.layout(of: $0).paneCount } ?? 0
        func number(_ phase: [String: JSONValue], _ field: String) -> Double {
            switch phase[field] {
            case .number(let value)?: return value
            case .integer(let value)?: return Double(value)
            default: return 0
            }
        }
        // **The drag alone.** Everything between the two drags exists to remeasure: the scroll
        // phase draws rows and the window resize marks every key stale, and both are supposed to
        // move the document. A swing taken over them says nothing about the gesture.
        let lengths = drag.compactMap { sample -> Double? in
            guard case .object(let fields) = sample,
                  case .number(let height)? = fields["contentHeight"] else { return nil }
            return height
        }
        let low = lengths.min() ?? 0
        let high = lengths.max() ?? 0
        let swing = low > 0 ? high / low : 0
        let grew = (lengths.last ?? 0) > (lengths.first ?? 0)

        let own: [String: JSONValue] = [
            // **What a run has to state before anything else**, because two batches of this probe
            // produced numbers that could not be compared and nobody could tell until afterwards.
            "paneWidth": .number(Double(pane.hold.bounds.width)),
            "windowWidth": .number(Double(window.frame.width)),
            "tableRows": .integer(pane.table?.numberOfRows ?? -1),
            "sessionRows": .integer(workspace.activeTranscript?.rows.count ?? 0),
            "arrangement": .string(arrangement),
            "panes": .integer(panes),
            "version": .string(
                Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            ),
            "build": .string(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"),
            "workspace": .string(workspace.workspace.id.rawValue),
            "workspaceName": .string(workspace.workspace.name),
            "driver": .string("storedHeight"),
            "drawnRows": .integer(TranscriptDrawn.rows),
            "travel": .number(Double(travel)),
            "step": .number(Double(step)),
            "band": .integer(band),
            "settleMs": .integer(settleMs),

            // **The tallest thing a row nobody has looked at was told it is.**
            //
            // **It depends on the width, and it was promoted here on the belief that it does
            // not.** The same estimator answered 6,025 at a 420 point pane and 170.67 at a 640
            // point one, on the same conversation, which makes sense the moment it is said out
            // loud: a narrow pane wraps prose into tall rows, and a tall row in a small sample is
            // exactly what a mean cannot survive. So this is a figure to read BESIDE the pane
            // width at the top of the report, never across runs at different ones.
            "largestGuess": .number(max(
                number(before, "largestGuess"),
                max(number(afterTaller, "largestGuess"), number(afterScrolling, "largestGuess"))
            )),

            // **The verdict: did the document run away during the DRAG.**
            //
            // Two of the earlier verdicts here were wrong and both are worth remembering. The
            // first asked whether a row had been silenced, which was the theory that had been
            // written down rather than the thing the owner can see. The second asked about the
            // whole run, so it counted the scroll and the resize phases, whose job is to move the
            // document, and it counted an estimate improving as evidence arrives as a fault.
            //
            // **The direction is reported rather than judged.** A document converging on the truth
            // is the system working and one running away from it is the bug, but this probe cannot
            // tell those apart on its own: it knows the true height of the rows that have been
            // MEASURED and not of the document, and on a conversation where most rows have never
            // been measured those are different questions. `measuredPointsPerRow` and
            // `largestGuess` are what a reader judges the direction with.
            //
            // Two, because a document that doubles under a hand is a document the reader is
            // somewhere else in, and because the old estimator's own drag swung by 3.86 while the
            // median's swung by 1.74 on the same gesture.
            // **The guess against what a measured row of this conversation actually is**, which
            // is the closest thing here to a figure that survives a change of width: both halves
            // of it move with the pane. Measured on the same conversation: 70 with the mean at a
            // 420 point pane, 6.1 with the mean at 640, 5.6 with the median at 747. The pathology
            // is the first of those and nothing else here separates it as cleanly.
            "guessRatio": .number(
                number(before, "measuredPointsPerRow") > 0
                    ? number(before, "largestGuess") / number(before, "measuredPointsPerRow")
                    : 0
            ),
            "documentSwingDuringDrag": .number(swing),
            "documentAtDragStart": .number(lengths.first ?? 0),
            "documentAtDragEnd": .number(lengths.last ?? 0),
            "documentMinDuringDrag": .number(low),
            "documentMaxDuringDrag": .number(high),
            "documentGrewDuringDrag": .bool(grew),
            "reproduced": .bool(swing >= 2),

            "before": .object(before),
            "afterTaller": .object(afterTaller),
            "afterScrolling": .object(afterScrolling),
            "afterWindowResize": .object(afterWindowResize),
            "steps": .array(drag),
            "stepsBack": .array(dragBack),
            // **The count that says whether the cause is ordinary or a once-in-four accident.**
            // A height reported from a pass that laid the row out at another width is the fault
            // that emptied the owner's transcript, and it is refused now rather than believed.
            // Nought here on every run would mean the account of it is wrong.
            "widthMismatches": .integer(TranscriptHoldCensus.widthMismatches),
            // Meaningless without this beside it: two refused reports out of forty nine cells
            // built is a rate, and two out of two thousand would be a different finding.
            "cellsBuilt": .integer(TranscriptHoldCensus.cellsBuilt),
            // **The signature of a starved cache**, which is what refusing reports would cost if
            // the guard were wrong: rows on screen, after the view has stopped moving, drawn at a
            // height nobody has measured. `repairTheScreen` is what stands behind it.
            "screenEstimated": .integer(TranscriptHoldCensus.screenEstimated),
            "screenEstimatedSettled": .integer(TranscriptHoldCensus.screenEstimatedSettled),
            "screensSeen": .integer(TranscriptHoldCensus.screensSeen),
            "mismatches": .array(TranscriptHoldCensus.mismatches.map { TranscriptStateDump.json(of: $0) }),
            "silences": .array(TranscriptHoldCensus.silences.map { TranscriptStateDump.json(of: $0) }),
            "transcriptHold": .map(TranscriptHoldCensus.summary()),
            "lostBefore": .integer(Int(number(before, "lostRows"))),
            "lostAfterDrag": .integer(Int(number(afterTaller, "lostRows"))),
            "lostAfterScrolling": .integer(Int(number(afterScrolling, "lostRows"))),
            "lostAfterWindowResize": .integer(Int(number(afterWindowResize, "lostRows"))),
        ]
        return .object(own.merging(harness.conditions(window: window)) { mine, _ in mine })
    }
}
