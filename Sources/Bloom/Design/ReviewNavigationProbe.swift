import AppKit
import BloomCore
import SwiftUI

#if DEBUG
/// Checks the landing position, not just whether a lazy diff loaded somewhere in the document.
/// All windows stay offscreen and navigation goes through the inspector's normal entry point.
@MainActor
enum ReviewNavigationProbe {
    static func run(directory: String, check: (Bool, String) -> Void) async {
        let app = AppModel()
        let model = WorkspaceModel(
            workspace: Workspace(repoID: .new(), name: "Navigation", branch: "main",
                                 path: directory + "/navigation", baseBranch: "main"),
            app: app
        )
        await model.refreshChanges()
        check(model.reviewFiles.count == 8, "navigation fixture did not load its eight files")
        FileReview.open(path: "File00.swift", in: model)
        let host = NSHostingView(rootView: Fixture(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host

        // Cold jumps, backward jumps, repeated destinations and previously prepared files.
        for index in [6, 2, 7, 0, 6, 6, 3] {
            let path = String(format: "File%02d.swift", index)
            FileReview.open(path: path, in: model)
            await settle(window)
            check(model.selectedFilePath == path,
                  "requested \(path), but the inspector selected \(model.selectedFilePath ?? "nil")")
            checkLanding(index: index, host: host, check: check)
        }
        // Rewrapping changes the heights above a destination which already finished loading.
        for width: CGFloat in [420, 1100, 600] {
            window.setContentSize(NSSize(width: width, height: 600))
            await settle(window)
            checkLanding(index: 3, host: host, check: check)
        }
        await checkKeyboardScrolling(host: host, window: window, check: check)
        FileReview.open(path: "File03.swift", in: model)
        await settle(window)
        checkLanding(index: 3, host: host, check: check)
        check(!window.isVisible && !window.isKeyWindow, "navigation probe activated its window")
        window.contentView = nil
        withExtendedLifetime(app) {}
    }

    private static func checkLanding(index: Int, host: NSView, check: (Bool, String) -> Void) {
        guard let scroll = scrollView(in: host),
              let text = firstLine(index: index, in: host) else {
            let details = textViews(in: host).map { String($0.string.prefix(24)) }
            let offset = scrollView(in: host)?.contentView.bounds.origin.y ?? -1
            check(false, "file \(index) did not render its first line at offset \(offset): \(details), prepared \(ReviewRunProbe.preparedLayouts)")
            return
        }
        let top = text.convert(text.bounds, to: scroll.contentView).minY - scroll.contentView.bounds.minY
        let header = InspectorLayout.reviewHeaderHeight
        check(top >= header - 1 && top <= header + 2 * CodeMetrics.rowHeight,
              "file \(index) landed with its first line at \(top), expected just below header \(header)")
    }

    private static func firstLine(index: Int, in view: NSView) -> WrappedCodeText.TextView? {
        if let text = view as? WrappedCodeText.TextView, text.string.hasPrefix("let file\(index)Line0 =") {
            return text
        }
        return view.subviews.lazy.compactMap { firstLine(index: index, in: $0) }.first
    }

    private static func textViews(in view: NSView) -> [WrappedCodeText.TextView] {
        if let text = view as? WrappedCodeText.TextView { return [text] }
        return view.subviews.flatMap { textViews(in: $0) }
    }

    private static func checkKeyboardScrolling(host: NSView, window: NSWindow, check: (Bool, String) -> Void) async {
        guard let input = inputView(in: host), let scroll = scrollView(in: host),
              let text = firstLine(index: 3, in: host),
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                          characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                                          keyCode: 125) else {
            check(false, "keyboard navigation fixture is missing its views")
            return
        }
        check(input.enclosingScrollView === scroll, "input observer is outside the review scroll view")
        check(window.makeFirstResponder(text), "could not focus the offscreen code view")
        // Call the observer directly. No event is posted to the app or the window server.
        input.handle(event)
        await settle(window)
        let before = scroll.contentView.bounds.origin.y
        text.scrollToVisible(NSRect(x: 0, y: 900, width: 10, height: 18))
        await settle(window)
        check(scroll.contentView.bounds.origin.y > before + 100, "navigation anchor undid keyboard scrolling")
    }

    private static func inputView(in view: NSView) -> ReviewNavigationInput.InputView? {
        if let input = view as? ReviewNavigationInput.InputView { return input }
        return view.subviews.lazy.compactMap { inputView(in: $0) }.first
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private static func settle(_ window: NSWindow) async {
        for _ in 0..<30 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    private struct Fixture: View {
        let model: WorkspaceModel

        var body: some View {
            if let tab = CenterTabStore.shared.review(for: model.workspace.id) {
                AllFilesReviewView(model: model, selectedPath: tab.path,
                                   navigationRevision: tab.reviewNavigationRevision)
            }
        }
    }
}
#endif
