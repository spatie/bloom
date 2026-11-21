import AppKit
import SwiftUI
import BloomCore

#if DEBUG
/// Replays the AttributeGraph abort: a pane's SwiftUI torn down while its window is in live resize.
///
///     Bloom --teardown-probe /tmp/teardown.json --teardown-workspace <id>
///           [--teardown-other <id>] [--teardown-cycles 40] [--teardown-mode home|switch]
///           [--window-hidden]
///
/// `home` shows Home, puts the window into live resize, narrows it, and selects a workspace, which
/// removes Home's `List` while AppKit still has it in live resize. `switch` does the same between
/// two workspaces. The report counts the cells a table was asked for while it was being removed,
/// which is the reentrant step in the crash, so a run that survived can say whether it went down
/// the path at all.
@MainActor
enum TeardownProbe {
    private static let harness = ProbeHarness(subject: "teardown")

    static var isRequested: Bool { harness.isRequested }

    static func schedule() {
        Task { @MainActor in await run() }
    }

    nonisolated(unsafe) private static var removing = false
    nonisolated(unsafe) private static var endedWhileRemoving = 0
    nonisolated(unsafe) private static var cellsWhileRemoving = 0

    private static func run() async {
        let (window, _) = await harness.window()
        guard let app = ProbeHarness.appModel else { harness.fail("no app model") }
        guard let first = ProbeHarness.value(for: "--teardown-workspace").map(WorkspaceID.init) else {
            harness.fail("--teardown-workspace named no workspace")
        }
        let other = ProbeHarness.value(for: "--teardown-other").map(WorkspaceID.init)
        let cycles = ProbeHarness.count("--teardown-cycles", or: 40)
        let mode = ProbeHarness.text("--teardown-mode", or: "home")
        // The control: the same steps with the window never put into live resize.
        let liveResize = !ProbeHarness.isPresent("--teardown-no-live-resize")
        countReentrantCells()
        harness.markStarted()

        let start = window.frame
        for cycle in 0..<cycles {
            app.selection = mode == "switch" ? .workspace(other ?? first) : .home
            try? await Task.sleep(for: .milliseconds(600))
            if liveResize { window.perform(NSSelectorFromString("_startLiveResize")) }
            for step in 1...6 {
                var frame = start
                frame.size.width -= CGFloat(step * 24)
                window.setFrame(frame, display: true)
                window.layoutIfNeeded()
                await Task.yield()
            }
            removing = true
            app.selection = .workspace(first)
            window.layoutIfNeeded()
            window.displayIfNeeded()
            removing = false
            if liveResize { window.perform(NSSelectorFromString("_endLiveResize")) }
            window.setFrame(start, display: true)
            try? "\(cycle)".write(toFile: harness.outputPath + ".cycle", atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data(
                "teardown probe: cycle \(cycle) ended=\(endedWhileRemoving) cells=\(cellsWhileRemoving)\n".utf8
            ))
            try? await Task.sleep(for: .milliseconds(400))
        }

        harness.write(.object([
            "mode": .string(mode),
            "liveResize": .bool(liveResize),
            "cycles": .number(Double(cycles)),
            "liveResizeEndedWhileRemoving": .number(Double(endedWhileRemoving)),
            "cellsBuiltWhileRemoving": .number(Double(cellsWhileRemoving)),
        ]))
        exit(0)
    }

    /// Counts what an `NSTableView` does on its way out of the window, which is where the crash is.
    private static func countReentrantCells() {
        let table: AnyClass = NSTableView.self
        let endSelector = NSSelectorFromString("viewDidEndLiveResize")
        if let method = class_getInstanceMethod(table, endSelector) {
            typealias End = @convention(c) (AnyObject, Selector) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: End.self)
            let block: @convention(block) (AnyObject) -> Void = { view in
                if removing { endedWhileRemoving += 1 }
                original(view, endSelector)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
        let makeSelector = NSSelectorFromString("makeViewForTableColumn:row:")
        if let method = class_getInstanceMethod(table, makeSelector) {
            typealias Make = @convention(c) (AnyObject, Selector, AnyObject?, Int) -> AnyObject?
            let original = unsafeBitCast(method_getImplementation(method), to: Make.self)
            let block: @convention(block) (AnyObject, AnyObject?, Int) -> AnyObject? = { view, column, row in
                if removing { cellsWhileRemoving += 1 }
                return original(view, makeSelector, column, row)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }
}
#endif
