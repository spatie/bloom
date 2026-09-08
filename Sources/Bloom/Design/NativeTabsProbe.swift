import AppKit
import BloomCore

#if DEBUG
@MainActor
enum NativeTabsProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--native-tabs-probe") }

    static func runAndExit() -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { await run() }
        RunLoop.main.run()
        exit(1)
    }

    private static func run() async {
        var checks = 0
        var failures: [String] = []
        func check(_ passed: Bool, _ message: String) {
            checks += 1
            if !passed { failures.append(message) }
        }
        var selected: String?
        var closed: String?
        var renamed: String?
        var renameRequested: PaneContent?
        var split = false
        var dropped: String?
        var moved = false
        func tab(_ id: String, _ title: String, busy: Bool = false) -> NativeStripTab {
            NativeStripTab(
                id: .tool(id), title: title, editableTitle: title, icon: .symbol("bubble.left"),
                isRunning: busy, closeTitle: "Close \(title)",
                select: { selected = id }, close: { closed = id }, rename: { renamed = $0 },
                splitRight: { split = true }
            )
        }
        var tabs = [tab("chat", "Chat", busy: true), tab("changes", "All changes"), tab("terminal", "Terminal")]
        let view = NativeTabStripView(frame: NSRect(x: 0, y: 0, width: 760, height: 32))
        let window = NativeTabProbeWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        view.onRenamingChange = { renameRequested = $0 }
        view.onDrop = { id, _ in dropped = id }
        view.onDragMove = { _ in moved = true }
        view.update(tabs: tabs, selectedID: .tool("chat"), renamingID: nil)
        await settle(view)
        check(view.control.font?.pointSize == 13, "the regular system font is not 13 points")
        check(view.control.controlSize == .regular, "the control is not regular sized")
        check(view.control.borderShape == .capsule, "the control is not a native capsule")
        check(view.control.frame.height == 24 && view.frame.height == 32, "the tab row lost its height alignment")
        check(indicators(view).count == 1, "the busy tab has no native spinner")
        check(view.control.selectedSegment == 0, "initial selection is incorrect")
        view.control.selectedSegment = 1
        view.control.sendAction(view.control.action, to: view.control.target)
        check(selected == "changes", "native selection did not select the tab")
        view.hover(at: CGPoint(x: view.segmentRect(2).midX, y: 12))
        let close = view.document.subviews.compactMap { $0 as? NSButton }.first { !$0.isHidden }
        close?.performClick(nil)
        check(closed == "terminal", "the hover close button closed the wrong tab")
        let menu = view.control.menu(forTab: .tool("chat"))!
        menu.performActionForItem(at: 0)
        check(renameRequested == .tool("chat"), "the context menu did not request rename")
        if let item = menu.items.firstIndex(where: { $0.title == "Split Right" }) { menu.performActionForItem(at: item) }
        check(split, "the split action was lost")
        view.update(tabs: tabs, selectedID: .tool("chat"), renamingID: .tool("chat"))
        await settle(view)
        let editor = view.document.subviews.compactMap { $0 as? NSTextField }.first!
        editor.stringValue = "Renamed chat"
        _ = view.control(editor, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        check(renamed == "Renamed chat" && renameRequested == nil, "rename did not commit and finish")
        view.update(tabs: tabs, selectedID: .tool("chat"), renamingID: .tool("chat"))
        await settle(view)
        let cancelled = view.document.subviews.compactMap { $0 as? NSTextField }.first!
        cancelled.stringValue = "Discard this name"
        _ = view.control(cancelled, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        check(renamed == "Renamed chat", "Escape committed the rename")
        let before = view.segmentRect(1)
        tabs[0].isRunning = false
        view.update(tabs: tabs, selectedID: .tool("chat"), renamingID: nil)
        check(indicators(view).isEmpty && before == view.segmentRect(1), "stopping activity moved the tabs")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects(["chat" as NSString])
        let drag = NativeTabProbeDrag(board: board, window: window)
        drag.draggingLocation = view.control.convert(CGPoint(x: view.segmentRect(2).midX, y: 12), to: nil)
        check(view.control.draggingEntered(drag) == .move && moved, "native drag feedback was lost")
        check(view.control.prepareForDragOperation(drag) && view.control.performDragOperation(drag), "native drop was refused")
        check(dropped == "chat", "the dropped tab identity was lost")
        board.clearContents()
        board.writeObjects(["different-workspace-tab" as NSString])
        check(view.control.draggingEntered(drag).isEmpty, "a foreign workspace tab was accepted")
        tabs += [tab("four", "A very long tab name that should remain accessible"), tab("five", "Browser"), tab("six", "Notes")]
        view.frame.size.width = 360
        view.update(tabs: tabs, selectedID: .tool("six"), renamingID: nil)
        await settle(view)
        check(view.control.bounds.width > view.scroll.contentSize.width, "overflow tabs were squeezed instead of scrollable")
        check(view.scroll.contentView.bounds.minX > 0, "the selected overflow tab was not revealed")
        view.reduceMotion = true
        tabs[0].isRunning = true
        view.frame.size.width = 760
        view.update(tabs: Array(tabs.prefix(3)), selectedID: .tool("chat"), renamingID: nil)
        await settle(view)
        check(indicators(view).count == 1, "Reduce Motion removed the busy indication")
        capture(view)
        view.update(tabs: [], selectedID: nil, renamingID: nil)
        check(view.control.segmentCount == 0 && view.control.isHidden, "an empty workspace kept ghost tabs")
        check(!window.isVisible, "the probe displayed a window")
        let result: [String: Any] = ["checks": checks, "passed": failures.isEmpty, "failures": failures]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(data)
        }
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func settle(_ view: NSView) async {
        view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(80))
        view.layoutSubtreeIfNeeded()
    }

    private static func indicators(_ view: NativeTabStripView) -> [NSProgressIndicator] {
        view.document.subviews.compactMap { $0 as? NSProgressIndicator }
    }

    private static func capture(_ view: NSView) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: "/tmp/bloom-native-tabs.png"))
    }
}

private final class NativeTabProbeWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

private final class NativeTabProbeDrag: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .move
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight = .none
    @MainActor init(board: NSPasteboard, window: NSWindow) {
        draggingPasteboard = board
        draggingDestinationWindow = window
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
#endif
