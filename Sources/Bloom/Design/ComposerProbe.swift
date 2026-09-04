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
/// The four phases are what the two theories predict, so a run can falsify either:
///
/// - `afterTaller`: rows with `known` nought and `drawsNothing` false, `hasCell` false, and
///   `silencedRows` above nought, if rows are being silenced. `cached` at nothing, and rows with
///   `known` nil, if the cache is being emptied instead.
/// - `afterScrolling`: a silenced row is still silenced and a merely unmeasured one is not, so
///   this phase is what separates them.
/// - `afterWindowResize`: everything measured again either way, because `rewidth` marks every key
///   stale. A run where even this does not repair it says both theories are wrong.
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
///           [--composer-arrangement chat|chat+browser] [--composer-url file:///…]
///           [--composer-travel 320] [--composer-step 24] [--composer-settle 1200]
///           [--composer-band 400] [--window-size 1440x900] [--window-hidden]
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
        guard let hold = holdView(in: contentView) else {
            harness.fail("no TranscriptHoldView found, so this is not the transcript's pane")
        }
        let pane = Pane(
            scroll: scroll,
            hold: hold,
            table: scroll.documentView as? NSTableView,
            coordinator: hold.delegate as? TranscriptTable.Coordinator
        )
        guard pane.coordinator != nil else {
            harness.fail("the hold view has no coordinator, so no row facts can be read")
        }

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

        // Taller, a step per vsync, which is the direction the bug is reported in.
        var samples = await drive(from: 0, to: travel, by: step, pane: pane)
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
        samples += await drive(from: travel, to: 0, by: -step, pane: pane)
        UserDefaults.standard.set(storedHeight, forKey: heightKey)

        harness.write(report(
            window: window,
            workspace: workspace,
            before: before,
            afterTaller: afterTaller,
            afterScrolling: afterScrolling,
            afterWindowResize: afterWindowResize,
            samples: samples
        ), echo: false)
        exit(0)
    }

    /// The four things a phase is read off, gathered once so no phase can pick up a different one.
    private struct Pane {
        var scroll: NSScrollView
        var hold: TranscriptHoldView
        var table: NSTableView?
        var coordinator: TranscriptTable.Coordinator?
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
        pane: Pane
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
    private static func scrollAbout(_ pane: Pane) async {
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
    private static func sample(at height: CGFloat, pane: Pane) -> JSONValue {
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
            // The number that tells an emptied cache from a missed row. See
            // `Coordinator.heightCacheCount`.
            "cached": .integer(pane.coordinator?.heightCacheCount ?? -1),
            "cacheWidth": .number(pane.coordinator?.heightCacheWidth ?? 0),
            "scrollAlpha": .number(Double(pane.scroll.alphaValue)),
            "held": .string(name(of: pane.hold.held)),
        ])
    }

    // MARK: - What the pane looked like

    /// Everything worth knowing about a transcript that is standing still, in one object.
    ///
    /// Taken four times, while nothing is moving. `lostRows` is the verdict: rows the cache has
    /// recorded at nothing that `TranscriptRowInk` expected to draw something. Those are the rows
    /// the reader cannot see and cannot get back.
    private static func dump(_ pane: Pane) -> [String: JSONValue] {
        let clip = pane.scroll.contentView
        let offset = Double(clip.bounds.origin.y)
        let end = Double(pane.scroll.endOffset)
        let range = pane.table.map { $0.rows(in: clip.documentVisibleRect) }
        let count = pane.table?.numberOfRows ?? -1
        let visible = range?.length ?? -1
        let facts = rowFacts(pane)
        let lost = facts.filter { $0.known == 0 && !$0.drawsNothing }

        var out: [String: JSONValue] = [
            "offset": .number(offset),
            "endOffset": .number(end),
            "overshoot": .number(offset - end),
            "contentHeight": .number(Double(pane.scroll.documentView?.frame.height ?? 0)),
            "viewportHeight": .number(Double(clip.bounds.height)),
            "viewportWidth": .number(Double(clip.bounds.width)),
            "scrollAlpha": .number(Double(pane.scroll.alphaValue)),
            "scrollFrame": rect(pane.scroll.frame),
            "holdBounds": rect(pane.hold.bounds),
            "held": .string(name(of: pane.hold.held)),
            // `frozen` is private to `TranscriptHoldView`, and this is the same question: a scroll
            // view sitting at anything other than its host's bounds is a frozen one.
            "scrollIsFrozen": .bool(pane.scroll.frame != pane.hold.bounds),
            "cached": .integer(pane.coordinator?.heightCacheCount ?? -1),
            "cacheWidth": .number(pane.coordinator?.heightCacheWidth ?? 0),
            "cacheIsReady": .bool(pane.coordinator?.heightCacheIsReady ?? false),
            "numberOfRows": .integer(count),
            "visibleRows": .integer(visible),
            "firstVisibleRow": .integer(range.map { $0.length > 0 ? $0.location : -1 } ?? -1),
            "rowViews": .integer(pane.table?.subviews.count ?? -1),
            "hostedRows": .integer(hostingViewCount(in: pane.table)),
            // The two verdicts, said by the probe rather than left to whoever reads the file.
            // Rows in the table and none in the viewport is the placement theory; rows recorded at
            // nothing that were expected to draw is the silence.
            "isBlank": .bool(count > 0 && visible == 0),
            "lostRows": .integer(lost.count),
            "bandRows": .integer(facts.count),
            "guessedRows": .integer(facts.filter { $0.known == nil && !$0.drawsNothing }.count),
            "cellsHeld": .integer(facts.filter(\.hasCell).count),
            "rows": .array(facts.map { json(of: $0) }),
        ]
        out["lost"] = .array(lost.prefix(40).map { json(of: $0) })
        return out
    }

    /// The rows either side of the ones on screen, which is where a row lost mid drag is.
    private static func rowFacts(_ pane: Pane) -> [TranscriptTable.Coordinator.RowFact] {
        guard let coordinator = pane.coordinator else { return [] }
        let visible = coordinator.visibleRowRange
        let count = pane.table?.numberOfRows ?? 0
        // A visible range of nothing is the blank itself, so the band is taken from whatever row
        // is under the offset instead of from a range that has collapsed. `row(at:)` answers -1
        // for a point past the last row, which is the parking case, and the band then starts at
        // the end of the table.
        let middle: Int
        if visible.isEmpty {
            let under = pane.table?.row(
                at: NSPoint(x: 0, y: pane.scroll.contentView.bounds.origin.y)
            ) ?? -1
            middle = under >= 0 ? under : max(0, count - band)
        } else {
            middle = visible.lowerBound
        }
        let lower = max(0, middle - band)
        let upper = min(count, max(visible.upperBound, middle) + band)
        guard lower < upper else { return [] }
        return coordinator.rowFacts(for: lower..<upper)
    }

    private static func json(of fact: TranscriptTable.Coordinator.RowFact) -> JSONValue {
        .object([
            "row": .integer(fact.row),
            "entry": .string(fact.name),
            "shape": .string(fact.shape),
            "drawsNothing": .bool(fact.drawsNothing),
            "known": fact.known.map { JSONValue.number($0) } ?? .null,
            "assumed": .number(fact.assumed),
            "measuredNothing": .bool(fact.measuredNothing),
            "needsMeasuring": .bool(fact.needsMeasuring),
            "told": .number(fact.told),
            "top": .number(fact.top),
            "hasCell": .bool(fact.hasCell),
        ])
    }

    private static func name(of held: TranscriptHoldView.Held?) -> String {
        guard let held else { return "none" }
        switch held {
        case .nothing: return "nothing"
        case .whatIsDrawn: return "whatIsDrawn"
        }
    }

    private static func rect(_ rect: CGRect) -> JSONValue {
        .object([
            "x": .number(Double(rect.origin.x)), "y": .number(Double(rect.origin.y)),
            "w": .number(Double(rect.width)), "h": .number(Double(rect.height)),
        ])
    }

    /// How many views under the table are hosting a SwiftUI graph, which is the number the three
    /// minute hang is quadratic in. By class name, because `NSHostingView` is generic and a probe
    /// has no business naming the row's view type.
    private static func hostingViewCount(in table: NSTableView?) -> Int {
        guard let table else { return -1 }
        var found = 0
        func walk(_ view: NSView) {
            if String(describing: type(of: view)).hasPrefix("NSHostingView") { found += 1 }
            for subview in view.subviews { walk(subview) }
        }
        walk(table)
        return found
    }

    private static func holdView(in root: NSView) -> TranscriptHoldView? {
        if let found = root as? TranscriptHoldView { return found }
        for subview in root.subviews {
            if let found = holdView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - Reporting

    private static func report(
        window: NSWindow,
        workspace: WorkspaceModel,
        before: [String: JSONValue],
        afterTaller: [String: JSONValue],
        afterScrolling: [String: JSONValue],
        afterWindowResize: [String: JSONValue],
        samples: [JSONValue]
    ) -> JSONValue {
        let tabs = WorkspaceTabsStore.shared
        let panes = tabs.selectedTab(in: workspace).map { tabs.layout(of: $0).paneCount } ?? 0
        func lost(_ phase: [String: JSONValue]) -> Int {
            guard case .integer(let count)? = phase["lostRows"] else { return -1 }
            return count
        }

        let own: [String: JSONValue] = [
            "driver": .string("storedHeight"),
            "arrangement": .string(arrangement),
            "workspace": .string(workspace.workspace.id.rawValue),
            "workspaceName": .string(workspace.workspace.name),
            "sessionRows": .integer(workspace.activeTranscript?.rows.count ?? 0),
            "drawnRows": .integer(TranscriptDrawn.rows),
            "panes": .integer(panes),
            "travel": .number(Double(travel)),
            "step": .number(Double(step)),
            "band": .integer(band),
            "settleMs": .integer(settleMs),
            "before": .object(before),
            "afterTaller": .object(afterTaller),
            "afterScrolling": .object(afterScrolling),
            "afterWindowResize": .object(afterWindowResize),
            "steps": .array(samples),
            "silences": .array(TranscriptHoldCensus.silences.map { json(of: $0) }),
            "transcriptHold": .map(TranscriptHoldCensus.summary()),
            // The answer, in four keys, so a run can be read without opening the tables. The
            // hypothesis is that the drag loses rows, a scroll does not get them back, and a width
            // change does.
            "lostAfterDrag": .integer(lost(afterTaller)),
            "lostAfterScrolling": .integer(lost(afterScrolling)),
            "lostAfterWindowResize": .integer(lost(afterWindowResize)),
            "reproduced": .bool(lost(afterTaller) > lost(before)),
        ]
        return .object(own.merging(harness.conditions(window: window)) { mine, _ in mine })
    }

    private static func json(of silence: TranscriptHoldCensus.Silence) -> JSONValue {
        .object([
            "row": .integer(silence.row),
            "source": .string(silence.source),
            "shape": .string(silence.shape),
            "columnWidth": .number(silence.columnWidth),
            "viewportWidth": .number(silence.viewportWidth),
            "viewportHeight": .number(silence.viewportHeight),
        ])
    }
}
