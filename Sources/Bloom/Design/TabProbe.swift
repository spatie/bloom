import AppKit
import SwiftUI
import QuartzCore
import BloomCore

/// Times what happens between picking a tab in the centre column and seeing it.
///
/// The third of the family, after `FrameProbe` (a drag) and `SwitchProbe` (a workspace). It exists
/// because the owner's complaint moved: switching workspace was measured and fixed, and switching
/// TAB was then reported as slow "certainly when there's already some content". That is a claim
/// about one column rebuilding itself, and only a timeline can say which part of the rebuild the
/// wait is in.
///
/// **One driver, and it is the only one this probe will ever have.** `WorkspaceTabsStore.select`
/// is called directly, which is everything a click on the strip does once the hit test is over.
/// The owner is sitting at this Mac while a run happens, so a probe that posted mouse events would
/// need the window in front and would take his keyboard: `SwitchProbe`'s `click` driver is the
/// faithful one for the sidebar and it is deliberately not copied here. A run needs no pointer, no
/// focus and no window in front.
///
///     Bloom --tab-probe /tmp/tab.json --tab-workspace <id> --tab-order chat,review,chat
///           [--tab-cycles 3] [--tab-settle 2500] [--window-size 1440x900]
///
/// Each entry of `--tab-order` names a tab rather than carrying its id, because a tool tab's id is
/// a uuid minted at runtime and a run has to be repeatable from a shell:
///
/// - `chat` is the workspace's first conversation, `chat:<sessionID>` a named one.
/// - `review`, `terminal`, `browser` and `notes` are that kind of tool tab, opened if the
///   workspace has not got one, so an order can name a tab the workspace has never had.
///
/// Everything that is not the tab pick itself is `ProbeHarness`: the flags, the window, the model,
/// the failure, the report.
@MainActor
enum TabProbe {
    private static let harness = ProbeHarness(subject: "tab")

    static var isRequested: Bool { harness.isRequested }

    // MARK: - Arguments

    private static var workspaceID: WorkspaceID? {
        ProbeHarness.value(for: "--tab-workspace").map(WorkspaceID.init)
    }

    private static var order: [String] {
        ProbeHarness.text("--tab-order", or: "chat").split(separator: ",").map(String.init)
    }

    private static var cycles: Int { ProbeHarness.count("--tab-cycles", or: 3) }

    /// How long a tab switch is given to finish before the next one starts. Shorter than
    /// `SwitchProbe`'s, because nothing here reaches `gh` or the network: what a tab switch starts
    /// is a transcript read at worst, and the deferred history a hundred milliseconds behind it.
    private static var settle: Int { ProbeHarness.count("--tab-settle", or: 2500) }

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
        // Deliberately never brought to the front, for the reason `ProbeHarness.window` gives: a
        // run happens while the owner is using his own copy of the app.
        if let driver = ProbeHarness.value(for: "--tab-driver"), driver != "programmatic" {
            harness.fail("the only driver is `programmatic`. See the head of TabProbe.swift")
        }

        let (window, contentView) = await harness.window()

        guard let app = ProbeHarness.appModel else { harness.fail("no app model") }
        guard let workspaceID else { harness.fail("--tab-workspace named no workspace") }
        app.selection = .workspace(workspaceID)

        // The workspace's own arrival, which this probe is not measuring: its sessions, its
        // transcript, `git status` and the first diff all land in here rather than inside a
        // measurement.
        try? await Task.sleep(for: .seconds(8))

        guard let workspace = app.existingModel(for: workspaceID) else {
            harness.fail("workspace \(workspaceID.rawValue) is not open")
        }

        let tabs = order.map { token -> (token: String, tab: PaneContent) in
            guard let tab = resolve(token, in: workspace) else {
                harness.fail("--tab-order named `\(token)`, which is not a tab this workspace can have")
            }
            return (token, tab)
        }
        // Opening a tool tab a moment ago changed the strip, and the first measurement must not be
        // paying for that.
        try? await Task.sleep(for: .seconds(2))

        let ticker = Ticker(view: contentView)
        ticker.start()
        SwitchTrace.isEnabled = true

        var runs: [JSONValue] = []

        // The first pass over the order is kept and labelled rather than thrown away, for the
        // reason `SwitchProbe` keeps its own: a first visit to a tab and a return to it are two
        // different switches, and the complaint being measured is about the second one.
        for entry in tabs {
            let run = await select(entry.tab, token: entry.token, of: workspace, ticker: ticker)
            runs.append(.object(run.merging(["pass": .string("cold")]) { current, _ in current }))
            try? await Task.sleep(for: .milliseconds(600))
        }

        for cycle in 0..<cycles {
            for entry in tabs {
                let run = await select(entry.tab, token: entry.token, of: workspace, ticker: ticker)
                let labels: [String: JSONValue] = [
                    "cycle": .integer(cycle), "pass": .string("warm"),
                ]
                runs.append(.object(run.merging(labels) { current, _ in current }))
                try? await Task.sleep(for: .milliseconds(600))
            }
        }

        SwitchTrace.isEnabled = false
        ticker.stop()

        let own: [String: JSONValue] = [
            "driver": .string("programmatic"),
            "workspace": .string(workspaceID.rawValue),
            "workspaceName": .string(workspace.workspace.name),
            "order": .strings(order),
            "cycles": .integer(cycles),
            "settleMs": .integer(settle),
            "sessionRows": .integer(workspace.activeTranscript?.rows.count ?? 0),
            "runs": .array(runs),
        ]
        harness.write(.object(own.merging(harness.conditions(window: window)) { mine, _ in mine }))
        exit(0)
    }

    /// One tab switch, from the selection to everything the timeline caught.
    private static func select(
        _ tab: PaneContent, token: String, of workspace: WorkspaceModel, ticker: Ticker
    ) async -> [String: JSONValue] {
        ticker.beginRun()
        PaneLayoutTiming.reset()
        PaneLayoutTiming.isEnabled = true
        // The same timeline `SwitchProbe` reads, begun by hand: the app itself only begins one
        // when the SIDEBAR selection changes, and nothing about a tab switch moves that.
        SwitchTrace.begin(workspaceID: workspace.workspace.id)
        FileHandle.standardError.write(
            Data("TAB \(token) \(Date().timeIntervalSince1970)\n".utf8)
        )

        WorkspaceTabsStore.shared.select(tab, in: workspace)

        try? await Task.sleep(for: .milliseconds(settle))
        PaneLayoutTiming.isEnabled = false

        return [
            "token": .string(token),
            "tab": .string(tab.id),
            "marks": SwitchTrace.timeline(),
            "frameCount": .integer(ticker.intervalsMs.count),
            "blocks": .numbers(ticker.blocksMs),
            "paneLayout": .map(PaneLayoutTiming.summary()),
            "panePasses": .map(PaneLayoutTiming.timeline()),
            "worstFrameMs": .number(ticker.intervalsMs.max() ?? 0),
        ]
    }

    // MARK: - Naming a tab

    /// What one entry of `--tab-order` names, opening a tool tab if the workspace has not got one.
    private static func resolve(_ token: String, in workspace: WorkspaceModel) -> PaneContent? {
        let id = workspace.workspace.id
        if token == "chat" {
            return WorkspaceTabsStore.shared.entries(in: workspace).first { $0.isChat }
        }
        if token.hasPrefix("chat:") {
            return .chat(SessionID(String(token.dropFirst("chat:".count))))
        }
        guard let kind = CenterTabKind(rawValue: token) else { return nil }
        let store = CenterTabStore.shared
        if let existing = store.tabs(for: id).first(where: { $0.kind == kind }) {
            return .tool(existing.id)
        }
        return .tool(store.add(kind: kind, workspaceID: id).id)
    }
}
