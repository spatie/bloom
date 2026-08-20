import AppKit
import SwiftUI
import QuartzCore
import Synchronization
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
@MainActor
enum SwitchProbe {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--switch-probe")
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
        value(for: "--switch-probe") ?? (NSTemporaryDirectory() + "bloom-switch-probe.json")
    }

    private static var order: [String] {
        (value(for: "--switch-order") ?? "").split(separator: ",").map(String.init)
    }

    private static var cycles: Int { Int(value(for: "--switch-cycles") ?? "") ?? 3 }
    private static var driver: String { value(for: "--switch-driver") ?? "programmatic" }
    /// How long a switch is given to finish before the next one starts. Everything asynchronous a
    /// switch kicks off has to be allowed to land inside the timeline, or the report is a
    /// measurement of the settle rather than of the switch.
    private static var settle: Int { Int(value(for: "--switch-settle") ?? "") ?? 4000 }

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

        guard !order.isEmpty else { return fail("--switch-order named no workspaces") }

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

        var runs: [[String: Any]] = []

        // The first pass is kept and labelled rather than thrown away. A first visit and a return
        // are two different switches: the first has nothing cached and reads the whole transcript
        // out of SQLite, the second has all of it in memory. Reporting only one of them would
        // answer half the question, and the owner does both all day.
        for id in order {
            let run = await switchTo(id, contentView: contentView, ticker: ticker)
            runs.append(run.merging(["pass": "cold"]) { current, _ in current })
            // A short gap only. `switchTo` has already waited out the settle.
            try? await Task.sleep(for: .milliseconds(800))
        }

        for cycle in 0..<cycles {
            for id in order {
                let run = await switchTo(id, contentView: contentView, ticker: ticker)
                runs.append(run.merging(["cycle": cycle, "pass": "warm"]) { current, _ in current })
                try? await Task.sleep(for: .milliseconds(800))
            }
        }

        // The case that breaks first: away before the asynchronous work has landed. Nothing from
        // the workspace being left may appear in the one being arrived at.
        let rapid = await rapidSwitches(contentView: contentView, ticker: ticker)

        SwitchTrace.isEnabled = false
        ticker.stop()

        write([
            "driver": driver,
            "configuration": buildConfiguration,
            "order": order,
            "cycles": cycles,
            "settleMs": settle,
            "windowSize": ["w": window.frame.width, "h": window.frame.height],
            "loadAverage": systemLoadAverage(),
            "runs": runs,
            "rapid": rapid,
        ])
        exit(0)
    }

    /// One switch, from the selection to everything the timeline caught.
    @discardableResult
    private static func switchTo(
        _ id: String, contentView: NSView, ticker: Ticker
    ) async -> [String: Any] {
        guard let app = model() else {
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
        let name = app.workspaces.first { $0.id == id }?.name ?? id
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
            "workspace": id,
            "name": name,
            "marks": SwitchTrace.timeline(),
            "frameCount": ticker.intervalsMs.count,
            "blocks": ticker.blocksMs,
            "paneLayout": PaneLayoutTiming.summary(),
            "panePasses": PaneLayoutTiming.timeline(),
            "worstFrameMs": ticker.intervalsMs.max() ?? 0,
        ]
    }

    /// Switches back and forth without waiting, then reports what is on screen at the end.
    ///
    /// The report is what the window settled on, not what it passed through: the point is that a
    /// refresh started for the workspace being left cannot land on the one being arrived at, and
    /// the way that shows up is the arrived-at workspace holding the other one's file list.
    private static func rapidSwitches(contentView: NSView, ticker: Ticker) async -> [String: Any] {
        guard let app = model(), order.count >= 2 else { return [:] }
        // The two furthest apart, so a leak is visible rather than plausible: in the fixture the
        // first and last workspaces are in different repositories with different files in them.
        let first = order[0]
        let second = order[order.count - 1]

        var flips: [[String: Any]] = []
        for step in 0..<8 {
            let target = step.isMultiple(of: 2) ? first : second
            app.selection = .workspace(target)
            try? await Task.sleep(for: .milliseconds(120))
            flips.append(["step": step, "selected": target])
        }

        // Everything in flight lands here.
        try? await Task.sleep(for: .seconds(8))

        let settled = app.selection.workspaceID ?? ""
        let model = app.existingModel(for: settled)
        // The file list is the tell. It is the one thing a switch fetches with a subprocess, so a
        // list belonging to the other workspace is a stale answer that landed in the wrong place.
        let paths = model?.changedFiles.prefix(4).map(\.path) ?? []
        return [
            "flips": flips,
            "settled": settled,
            "settledName": app.workspaces.first { $0.id == settled }?.name ?? "",
            "changedFileCount": model?.changedFiles.count ?? 0,
            "changedFileSample": Array(paths),
            // Proof the sample belongs to the settled workspace: every path is inside its worktree
            // in the fixture, so a leak from the other one is visible as a different prefix.
            "worktree": model?.workspace.path ?? "",
            "isLoadingChanges": model?.isLoadingChanges ?? false,
            "sessionCount": model?.sessions.count ?? 0,
            // The other list a switch fetches with a subprocess, and the one that used to be the
            // previous workspace's for as long as git took to answer.
            "fileTreeRoots": model?.fileTree[""]?.count ?? 0,
            "fileTreeSample": (model?.fileTree[""] ?? []).prefix(3).map(\.name),
            "sessionTitles": model?.sessions.map(\.title) ?? [],
            "transcriptRows": model?.activeTranscript?.rows.count ?? 0,
            "otherWorkspaceFileCount": app.existingModel(
                for: settled == first ? second : first
            )?.changedFiles.count ?? 0,
        ]
    }

    // MARK: - The click driver

    /// Clicks the sidebar row for a workspace, by finding the row that carries its name.
    ///
    /// The row is found in the real view hierarchy rather than by counting: a project header is a
    /// row too, and so is Home, so an index would be a guess that a reordered sidebar breaks
    /// silently. The name comes off the row's accessibility label, which is the same string
    /// VoiceOver reads.
    private static func click(row id: String, contentView: NSView) async {
        guard let app = model() else { return }
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
        let done = Mutex(false)
        Thread.detachNewThread {
            post(.leftMouseDown, at: flipped, pid: pid)
            Thread.sleep(forTimeInterval: 0.03)
            post(.leftMouseUp, at: flipped, pid: pid)
            done.withLock { $0 = true }
        }
        while !done.withLock({ $0 }) {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
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

    private nonisolated static func post(_ type: CGEventType, at point: CGPoint, pid: pid_t) {
        guard let event = CGEvent(
            mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left
        ) else { return }
        event.postToPid(pid)
    }

    // MARK: - Reaching the model

    /// The app's state, handed over by the delegate on launch. Weak, because a probe has no
    /// business keeping the app alive.
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
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]))
            ?? Data()
        try? data.write(to: URL(fileURLWithPath: outputPath))
        FileHandle.standardError.write(Data("switch probe wrote \(outputPath)\n".utf8))
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("switch probe: \(message)\n".utf8))
        exit(1)
    }
}

/// Drives `SwitchTrace.tick` once per vsync, and records how long each frame took.
///
/// The frame intervals matter as much as the marks. A switch whose data is ready in 40ms and whose
/// next frame takes 700ms is not a slow database, it is a slow layout, and only the interval says
/// which of the two is being looked at.
@MainActor
private final class Ticker {
    private var link: CADisplayLink?
    private let view: NSView
    private var last: CFTimeInterval = 0
    private(set) var intervalsMs: [Double] = []

    init(view: NSView) { self.view = view }

    func start() {
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// Where each frame fell relative to the switch, and how long it took. The offsets are what
    /// turn a list of intervals into a picture of when the window was frozen.
    private(set) var blocksMs: [[Double]] = []
    private var origin: CFTimeInterval = 0

    /// Clears the frame record so each switch reports only its own frames.
    func beginRun() {
        intervalsMs.removeAll()
        blocksMs.removeAll()
        last = 0
        origin = CACurrentMediaTime()
    }

    @objc private func tick() {
        SwitchTrace.tick()
        let now = CACurrentMediaTime()
        defer { last = now }
        guard last != 0 else { return }
        let interval = (now - last) * 1000
        intervalsMs.append(interval)
        // Only the frames that were late. A list of six hundred 8ms ticks says nothing, and the
        // ones over two frame times are exactly the moments the window stood still.
        if interval > 20 {
            blocksMs.append([(last - origin) * 1000, interval])
        }
    }
}
