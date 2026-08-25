import AppKit
import SwiftUI
import BloomCore

/// Times what happens between clicking a workspace in the sidebar and seeing it.
///
/// The sibling of `FrameProbe`, and it exists for the same reason: "switching takes about a
/// second" is an impression, and an impression cannot say which second. This one drives real
/// selections, records `SwitchTrace`'s timeline for each, and writes the lot as JSON.
///
/// Two drivers, the same split `FrameProbe` makes:
///
/// - `click` posts real `CGEvent`s at the sidebar row's own rectangle, to THIS process's pid, so
///   the selection travels the whole path a hand does: hit testing, the list's selection binding,
///   `commitSelection`, the setter. It needs the app frontmost, and only this driver does.
/// - `programmatic` writes `app.selection` directly. Everything from the setter onwards is
///   identical, and a run needs no pointer and cannot be spoiled by the window losing focus.
///
///     Bloom --switch-probe /tmp/switch.json --switch-order id1,id2 [--switch-cycles 3]
///           [--switch-driver click|programmatic] [--switch-settle 4000] [--window-size 1440x900]
///
/// Everything that is not the selection itself is `ProbeHarness`: the flags, the window, the
/// model, the failure, the report.
@MainActor
enum SwitchProbe {
    private static let harness = ProbeHarness(subject: "switch")

    static var isRequested: Bool { harness.isRequested }

    // MARK: - Arguments

    private static var order: [WorkspaceID] {
        ProbeHarness.text("--switch-order", or: "")
            .split(separator: ",")
            .map { WorkspaceID(String($0)) }
    }

    private static var cycles: Int { ProbeHarness.count("--switch-cycles", or: 3) }
    private static var driver: String { ProbeHarness.text("--switch-driver", or: "programmatic") }
    /// How long a switch is given to finish before the next one starts. Everything asynchronous a
    /// switch kicks off has to be allowed to land inside the timeline, or the report is a
    /// measurement of the settle rather than of the switch.
    private static var settle: Int { ProbeHarness.count("--switch-settle", or: 4000) }

    // MARK: - Entry

    static func schedule() {
        Task { @MainActor in await run() }
    }

    /// The state, handed over by the delegate on launch. See `ProbeHarness.attach`, which holds it.
    static func attach(_ model: AppModel) {
        guard isRequested else { return }
        ProbeHarness.attach(model)
    }

    private static func run() async {
        let (window, contentView) = await harness.window()

        guard !order.isEmpty else { harness.fail("--switch-order named no workspaces") }

        // Everything a fresh launch kicks off settles before the first measurement, so the first
        // switch is not paying for the sidebar's own arrival.
        try? await Task.sleep(for: .seconds(4))

        if driver == "click" {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(600))
        }

        let ticker = Ticker(view: contentView)
        ticker.start()
        SwitchTrace.isEnabled = true

        var runs: [JSONValue] = []

        // The first pass is kept and labelled rather than thrown away. A first visit and a return
        // are two different switches: the first has nothing cached and reads the whole transcript
        // out of SQLite, the second has all of it in memory. Reporting only one of them would
        // answer half the question, and the owner does both all day.
        for id in order {
            let run = await switchTo(id, contentView: contentView, ticker: ticker)
            runs.append(.object(run.merging(["pass": .string("cold")]) { current, _ in current }))
            // A short gap only. `switchTo` has already waited out the settle.
            try? await Task.sleep(for: .milliseconds(800))
        }

        for cycle in 0..<cycles {
            for id in order {
                let run = await switchTo(id, contentView: contentView, ticker: ticker)
                let labels: [String: JSONValue] = [
                    "cycle": .integer(cycle), "pass": .string("warm"),
                ]
                runs.append(.object(run.merging(labels) { current, _ in current }))
                try? await Task.sleep(for: .milliseconds(800))
            }
        }

        // Whether a reader who was NOT at the live end is put back where they were, which is the
        // half of `TranscriptResume` the runs above cannot reach: a probe that only ever sits at
        // the end measures the flag, never the anchor.
        let kept = await keepsItsPlace(contentView: contentView, ticker: ticker)

        // The case that breaks first: away before the asynchronous work has landed. Nothing from
        // the workspace being left may appear in the one being arrived at.
        let rapid = await rapidSwitches(contentView: contentView, ticker: ticker)

        SwitchTrace.isEnabled = false
        ticker.stop()

        let own: [String: JSONValue] = [
            "driver": .string(driver),
            "order": .strings(order.map(\.rawValue)),
            "cycles": .integer(cycles),
            "settleMs": .integer(settle),
            "runs": .array(runs),
            "rapid": .object(rapid),
            "keepsItsPlace": .object(kept),
        ]
        harness.write(.object(own.merging(harness.conditions(window: window)) { mine, _ in mine }))
        exit(0)
    }

    /// One switch, from the selection to everything the timeline caught.
    @discardableResult
    private static func switchTo(
        _ id: WorkspaceID, contentView: NSView, ticker: Ticker
    ) async -> [String: JSONValue] {
        guard let app = ProbeHarness.appModel else {
            FileHandle.standardError.write(Data("switch probe: no app model\n".utf8))
            return [:]
        }
        ticker.beginRun()
        // Which pane's layout the freeze is in. `FrameProbe` uses the same counters for the same
        // reason: "the window stood still for 300ms" is not an answer until it says which of the
        // two columns stood still.
        PaneLayoutTiming.reset()
        PaneLayoutTiming.isEnabled = true
        // A line on stderr with the wall clock on it, so a film of the window taken by another
        // process can be lined up with the switch it is a film of.
        let name = app.workspaces.first { $0.id == id }?.name ?? id.rawValue
        FileHandle.standardError.write(
            Data("SWITCH \(name) \(Date().timeIntervalSince1970)\n".utf8)
        )

        switch driver {
        case "click": await click(row: id, contentView: contentView)
        default: app.selection = .workspace(id)
        }

        // Long enough for everything a switch starts to land, including `gh`.
        try? await Task.sleep(for: .milliseconds(settle))
        PaneLayoutTiming.isEnabled = false

        return [
            "workspace": .string(id.rawValue),
            "name": .string(name),
            // Where the switch left the reader, which is the whole of what "it did not keep my
            // place" means. See `ProbeHarness.scrollPlace`.
            "place": .object(ProbeHarness.scrollPlace(
                ProbeHarness.transcriptScrollView(in: contentView)
            )),
            "marks": SwitchTrace.timeline(),
            "frameCount": .integer(ticker.intervalsMs.count),
            "blocks": .numbers(ticker.blocksMs),
            "paneLayout": .map(PaneLayoutTiming.summary()),
            "panePasses": .map(PaneLayoutTiming.timeline()),
            "worstFrameMs": .number(ticker.intervalsMs.max() ?? 0),
        ]
    }

    /// Leaves a reader part way up a conversation, goes somewhere else, and comes back.
    ///
    /// The offsets either side are the whole report. They are not required to be equal to the
    /// point: the rows above the viewport are re-measured on the way back, so an anchor that lands
    /// the same ROW at the top can legitimately land a few points from where it was. What would
    /// fail is landing at the live end (the flag was written when it should not have been), at the
    /// top (nothing was restored), or at the first unread row, which is what a refused restore
    /// used to do and is halfway up a long conversation.
    private static func keepsItsPlace(
        contentView: NSView, ticker: Ticker
    ) async -> [String: JSONValue] {
        guard let app = ProbeHarness.appModel, order.count >= 2 else { return [:] }
        let subject = order[0]

        app.selection = .workspace(subject)
        try? await Task.sleep(for: .milliseconds(settle))
        guard let scroll = ProbeHarness.transcriptScrollView(in: contentView) else { return [:] }

        // A long way up, so the answer cannot be confused with a reader who never left the end.
        let travel = ProbeHarness.scrollableHeight(of: scroll)
        let target = max(0, travel - 2_000)
        scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
        // Long enough for the scroll to settle and for the pane to write down where it is: the
        // record is made when a scroll ENDS, which is a phase change rather than a frame.
        try? await Task.sleep(for: .seconds(2))
        let left = ProbeHarness.scrollPlace(scroll)

        await switchTo(order[order.count - 1], contentView: contentView, ticker: ticker)
        await switchTo(subject, contentView: contentView, ticker: ticker)

        let returned = ProbeHarness.scrollPlace(
            ProbeHarness.transcriptScrollView(in: contentView)
        )
        var report: [String: JSONValue] = ["left": .object(left), "returned": .object(returned)]
        if case .number(let before)? = left["offset"], case .number(let after)? = returned["offset"] {
            report["movedPoints"] = .number(abs(after - before))
        }
        return report
    }

    /// Switches back and forth without waiting, then reports what is on screen at the end.
    ///
    /// The report is what the window settled on, not what it passed through: the point is that a
    /// refresh started for the workspace being left cannot land on the one being arrived at, and
    /// the way that shows up is the arrived-at workspace holding the other one's file list.
    private static func rapidSwitches(
        contentView: NSView, ticker: Ticker
    ) async -> [String: JSONValue] {
        guard let app = ProbeHarness.appModel, order.count >= 2 else { return [:] }
        // The two furthest apart, so a leak is visible rather than plausible: in the fixture the
        // first and last workspaces are in different repositories with different files in them.
        let first = order[0]
        let second = order[order.count - 1]

        var flips: [JSONValue] = []
        for step in 0..<8 {
            let target = step.isMultiple(of: 2) ? first : second
            app.selection = .workspace(target)
            try? await Task.sleep(for: .milliseconds(120))
            flips.append(.object(["step": .integer(step), "selected": .string(target.rawValue)]))
        }

        // Everything in flight lands here.
        try? await Task.sleep(for: .seconds(8))

        let settled = app.selection.workspaceID
        let model = settled.flatMap { app.existingModel(for: $0) }
        // The file list is the tell. It is the one thing a switch fetches with a subprocess, so a
        // list belonging to the other workspace is a stale answer that landed in the wrong place.
        let paths = model?.changedFiles.prefix(4).map(\.path) ?? []
        return [
            "flips": .array(flips),
            "settled": .string(settled?.rawValue ?? ""),
            "settledName": .string(app.workspaces.first { $0.id == settled }?.name ?? ""),
            "changedFileCount": .integer(model?.changedFiles.count ?? 0),
            "changedFileSample": .strings(paths),
            // Proof the sample belongs to the settled workspace: every path is inside its worktree
            // in the fixture, so a leak from the other one is visible as a different prefix.
            "worktree": .string(model?.workspace.path ?? ""),
            "isLoadingChanges": .bool(model?.isLoadingChanges ?? false),
            "sessionCount": .integer(model?.sessions.count ?? 0),
            // The other list a switch fetches with a subprocess, and the one that used to be the
            // previous workspace's for as long as git took to answer.
            "fileTreeRoots": .integer(model?.fileTree[""]?.count ?? 0),
            "fileTreeSample": .strings((model?.fileTree[""] ?? []).prefix(3).map(\.name)),
            "sessionTitles": .strings(model?.sessions.map(\.title) ?? []),
            "transcriptRows": .integer(model?.activeTranscript?.rows.count ?? 0),
            "otherWorkspaceFileCount": .integer(
                app.existingModel(for: settled == first ? second : first)?.changedFiles.count ?? 0
            ),
        ]
    }

    // MARK: - The click driver

    /// Clicks the sidebar row for a workspace, by finding the row that carries its name.
    ///
    /// The row is found in the real view hierarchy rather than by counting: a project header is a
    /// row too, and so is Home, so an index would be a guess that a reordered sidebar breaks
    /// silently. The name comes off the row's accessibility label, which is the same string
    /// VoiceOver reads.
    private static func click(row id: WorkspaceID, contentView: NSView) async {
        guard let app = ProbeHarness.appModel else { return }
        guard let window = contentView.window,
              let name = app.workspaces.first(where: { $0.id == id })?.name,
              let rect = rowRect(named: name, in: contentView) else {
            // A row that cannot be found is worth saying so rather than silently measuring a
            // programmatic switch and reporting it as a click.
            FileHandle.standardError.write(Data("switch probe: no sidebar row for \(id)\n".utf8))
            app.selection = .workspace(id)
            return
        }

        let inWindow = contentView.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        guard let screen = window.screen ?? NSScreen.main else { return }
        let flipped = CGPoint(x: onScreen.x, y: screen.frame.maxY - onScreen.y)

        let pid = ProcessInfo.processInfo.processIdentifier
        await harness.onEventThread(polling: .milliseconds(2)) {
            ProbeHarness.post(.leftMouseDown, at: flipped, pid: pid)
            Thread.sleep(forTimeInterval: 0.03)
            ProbeHarness.post(.leftMouseUp, at: flipped, pid: pid)
        }
    }

    private static func rowRect(named name: String, in root: NSView) -> CGRect? {
        var found: CGRect?
        func walk(_ view: NSView) {
            if found != nil { return }
            if view.className.contains("TableRowView") || view.className.contains("ListRow") {
                if label(of: view)?.contains(name) == true {
                    found = view.convert(view.bounds, to: root)
                    return
                }
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return found
    }

    /// Every string this row draws, joined. A SwiftUI row is a stack of text layers rather than
    /// one label, so the name has to be gathered rather than read.
    private static func label(of view: NSView) -> String? {
        var parts: [String] = []
        func walk(_ view: NSView) {
            if let text = view.accessibilityLabel(), !text.isEmpty { parts.append(text) }
            if let value = view.accessibilityValue() as? String, !value.isEmpty { parts.append(value) }
            for subview in view.subviews { walk(subview) }
        }
        walk(view)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
