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
@MainActor
enum TabProbe {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--tab-probe")
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
        value(for: "--tab-probe") ?? (NSTemporaryDirectory() + "bloom-tab-probe.json")
    }

    private static var workspaceID: WorkspaceID? {
        value(for: "--tab-workspace").map(WorkspaceID.init)
    }

    private static var order: [String] {
        (value(for: "--tab-order") ?? "chat").split(separator: ",").map(String.init)
    }

    private static var cycles: Int { Int(value(for: "--tab-cycles") ?? "") ?? 3 }

    /// How long a tab switch is given to finish before the next one starts. Shorter than
    /// `SwitchProbe`'s, because nothing here reaches `gh` or the network: what a tab switch starts
    /// is a transcript read at worst, and the deferred history a hundred milliseconds behind it.
    private static var settle: Int { Int(value(for: "--tab-settle") ?? "") ?? 2500 }

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
        // Deliberately never brought to the front, for the reason `FrameProbe` gives: a run
        // happens while the owner is using his own copy of the app.
        if let driver = value(for: "--tab-driver"), driver != "programmatic" {
            fail("the only driver is `programmatic`. See the head of TabProbe.swift")
        }

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
            fail("no window to probe")
        }

        if let size = windowSize {
            window.setContentSize(size)
            window.layoutIfNeeded()
            try? await Task.sleep(for: .seconds(1))
        }

        guard let app = model() else { fail("no app model") }
        guard let workspaceID else { fail("--tab-workspace named no workspace") }
        app.selection = .workspace(workspaceID)

        // The workspace's own arrival, which this probe is not measuring: its sessions, its
        // transcript, `git status` and the first diff all land in here rather than inside a
        // measurement.
        try? await Task.sleep(for: .seconds(8))

        guard let workspace = app.existingModel(for: workspaceID) else {
            fail("workspace \(workspaceID.rawValue) is not open")
        }

        let tabs = order.map { token -> (token: String, tab: PaneContent) in
            guard let tab = resolve(token, in: workspace) else {
                fail("--tab-order named `\(token)`, which is not a tab this workspace can have")
            }
            return (token, tab)
        }
        // Opening a tool tab a moment ago changed the strip, and the first measurement must not be
        // paying for that.
        try? await Task.sleep(for: .seconds(2))

        let ticker = Ticker(view: contentView)
        ticker.start()
        SwitchTrace.isEnabled = true

        var runs: [[String: Any]] = []

        // The first pass over the order is kept and labelled rather than thrown away, for the
        // reason `SwitchProbe` keeps its own: a first visit to a tab and a return to it are two
        // different switches, and the complaint being measured is about the second one.
        for entry in tabs {
            runs.append(
                await select(entry.tab, token: entry.token, of: workspace, ticker: ticker)
                    .merging(["pass": "cold"]) { current, _ in current }
            )
            try? await Task.sleep(for: .milliseconds(600))
        }

        for cycle in 0..<cycles {
            for entry in tabs {
                runs.append(
                    await select(entry.tab, token: entry.token, of: workspace, ticker: ticker)
                        .merging(["cycle": cycle, "pass": "warm"]) { current, _ in current }
                )
                try? await Task.sleep(for: .milliseconds(600))
            }
        }

        SwitchTrace.isEnabled = false
        ticker.stop()

        write([
            "driver": "programmatic",
            "configuration": buildConfiguration,
            "workspace": workspaceID.rawValue,
            "workspaceName": workspace.workspace.name,
            "order": order,
            "cycles": cycles,
            "settleMs": settle,
            "windowSize": ["w": window.frame.width, "h": window.frame.height],
            "loadAverage": systemLoadAverage(),
            "sessionRows": workspace.activeTranscript?.rows.count ?? 0,
            "runs": runs,
        ])
        exit(0)
    }

    /// One tab switch, from the selection to everything the timeline caught.
    private static func select(
        _ tab: PaneContent, token: String, of workspace: WorkspaceModel, ticker: Ticker
    ) async -> [String: Any] {
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
            "token": token,
            "tab": tab.id,
            "marks": SwitchTrace.timeline(),
            "frameCount": ticker.intervalsMs.count,
            "blocks": ticker.blocksMs,
            "paneLayout": PaneLayoutTiming.summary(),
            "panePasses": PaneLayoutTiming.timeline(),
            "worstFrameMs": ticker.intervalsMs.max() ?? 0,
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

    // MARK: - Reaching the model

    /// The app's state, handed over by the delegate on launch. Weak, for the reason `SwitchProbe`
    /// gives: a probe has no business keeping the app alive.
    private weak static var app: AppModel?

    static func attach(_ model: AppModel) {
        guard isRequested else { return }
        app = model
    }

    private static func model() -> AppModel? { app }

    // MARK: - Reporting

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

    private static func write(_ report: [String: Any]) {
        // Asked before the encode, for the reason written down in `SwitchProbe.write`: a typed id
        // in a `[String: Any]` arrives as `__SwiftValue` and `JSONSerialization` raises rather
        // than throwing, which is not something `try?` catches, so it killed a run on its last
        // line.
        guard JSONSerialization.isValidJSONObject(report) else {
            fail("the report holds a value JSON cannot carry, probably an id that needed .rawValue")
        }
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]))
            ?? Data()
        try? data.write(to: URL(fileURLWithPath: outputPath))
        FileHandle.standardError.write(Data("tab probe wrote \(outputPath)\n".utf8))
    }

    /// `Never`, so the callers above can end the run with it from inside a `guard`.
    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("tab probe: \(message)\n".utf8))
        exit(1)
    }
}
