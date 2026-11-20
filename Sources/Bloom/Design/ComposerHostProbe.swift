import AppKit
import BloomCore

#if DEBUG
/// Tries to replay the second AttributeGraph abort, the one under the composer's embedded hosting
/// view, and has not managed it yet. See `ComposerDropRootModel` for the reports it is chasing.
///
///     Bloom --composerhost-probe /tmp/composerhost.json --composerhost-workspace <id>
///           [--composerhost-other <id>] [--composerhost-cycles 400] [--composerhost-send]
///           [--composerhost-grouping status] [--composerhost-settle-every 3] [--window-hidden]
///
/// Each cycle writes a draft that changes the composer's height and then clears it, or with
/// `--composerhost-send` does what pressing Return does without starting a turn
/// (`TranscriptModel.probeSend`), and every seventh cycle swaps the workspace the pane shows.
/// Nothing here is timed: a run either reaches its last cycle and writes its report, or the process
/// aborts and the `.cycle` file beside the report says how far it got.
@MainActor
enum ComposerHostProbe {
    private static let harness = ProbeHarness(subject: "composerhost")

    static var isRequested: Bool { harness.isRequested }

    static func schedule() {
        Task { @MainActor in await run() }
    }

    private static func run() async {
        let (window, _) = await harness.window()
        guard let app = ProbeHarness.appModel else { harness.fail("no app model") }
        guard let first = ProbeHarness.value(for: "--composerhost-workspace").map(WorkspaceID.init) else {
            harness.fail("--composerhost-workspace named no workspace")
        }
        let other = ProbeHarness.value(for: "--composerhost-other").map(WorkspaceID.init)
        let cycles = ProbeHarness.count("--composerhost-cycles", or: 400)
        // `--composerhost-grouping status` sorts the sidebar by what each workspace is doing, so a
        // send moves the row into Working and a settle moves it out again. Written into the dev
        // copy's own defaults, which is the only domain a probe run reads.
        if let grouping = ProbeHarness.value(for: "--composerhost-grouping") {
            UserDefaults.standard.set(grouping, forKey: SidebarGrouping.storageKey)
        }
        let settleEvery = ProbeHarness.count("--composerhost-settle-every", or: 3)
        app.selection = .workspace(first)
        try? await Task.sleep(for: .seconds(3))
        harness.markStarted()

        let drafts = ["a", String(repeating: "line\n", count: 8), "short", String(repeating: "x ", count: 400)]
        let sends = ProbeHarness.isPresent("--composerhost-send")
        var afterSend: Set<Int> = []
        var afterSettle: Set<Int> = []
        for cycle in 0..<cycles {
            if let other, cycle % 7 == 6 {
                app.selection = .workspace(cycle % 14 == 6 ? other : first)
            }
            let transcript = AppModel.probeSelectedModel?.activeTranscript
            let text = drafts[cycle % drafts.count]
            transcript?.draft = text
            // One display cycle with the draft in the box, as typing leaves it.
            try? await Task.sleep(for: .milliseconds(20))
            if sends {
                transcript?.probeSend(text)
            } else {
                transcript?.draft = ""
            }
            // The send's own pass, left to the display cycle rather than forced, because that is
            // where the crash reports have it.
            try? await Task.sleep(for: .milliseconds(20))
            window.layoutIfNeeded()
            window.displayIfNeeded()
            if sends { afterSend.insert(sidebarSelectedRow(in: window)) }
            if sends, cycle % settleEvery == settleEvery - 1 {
                transcript?.probeSettle()
                try? await Task.sleep(for: .milliseconds(20))
                window.layoutIfNeeded()
                afterSettle.insert(sidebarSelectedRow(in: window))
            }
            await Task.yield()
            if cycle % 50 == 0 {
                FileHandle.standardError.write(Data("composerhost probe: cycle \(cycle)\n".utf8))
            }
            try? "\(cycle)".write(toFile: harness.outputPath + ".cycle", atomically: true, encoding: .utf8)
        }
        AppModel.probeSelectedModel?.activeTranscript?.probeSettle()
        AppModel.probeSelectedModel?.activeTranscript?.draft = ""
        harness.write(.object([
            "cycles": .number(Double(cycles)),
            // The selected row's place in the sidebar after a send and after a settle. Different
            // numbers are the proof that the row changed section at all.
            "rowsAfterSend": .array(afterSend.map { .number(Double($0)) }),
            "rowsAfterSettle": .array(afterSettle.map { .number(Double($0)) }),
        ]))
        exit(0)
    }

    /// The sidebar's selected row, or minus one. The sidebar is the outline with the most rows.
    private static func sidebarSelectedRow(in window: NSWindow) -> Int {
        var outlines: [NSOutlineView] = []
        func walk(_ view: NSView) {
            if let outline = view as? NSOutlineView { outlines.append(outline) }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView?.superview { walk(root) }
        return outlines.max { $0.numberOfRows < $1.numberOfRows }?.selectedRow ?? -1
    }
}
#endif
