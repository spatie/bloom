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
        model.selectedFilePath = "File00.swift"
        FileReview.setShowsAllFiles(true, in: model)
        let host = NSHostingView(rootView: Fixture(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host

        // Cold jumps, backward jumps, repeated destinations and previously prepared files.
        for index in [6, 2, 7, 0, 6, 6, 3] {
            let path = String(format: "File%02d.swift", index)
            ReviewRunProbe.clearTrace()
            model.selectedFilePath = path
            FileReview.setShowsAllFiles(true, in: model)
            await settle(window)
            check(model.selectedFilePath == path,
                  "requested \(path), but the inspector selected \(model.selectedFilePath ?? "nil")")
            checkLanding(index: index, host: host, model: model, context: "after jumping to \(path)", check: check)
        }
        // Rewrapping changes the heights above a destination which already finished loading.
        for width: CGFloat in [420, 1100, 600] {
            ReviewRunProbe.clearTrace()
            window.setContentSize(NSSize(width: width, height: 600))
            await settle(window)
            checkLanding(index: 3, host: host, model: model, context: "after resizing to \(Int(width)) wide", check: check)
        }
        await checkKeyboardScrolling(host: host, window: window, check: check)
        ReviewRunProbe.clearTrace()
        model.selectedFilePath = "File03.swift"
        FileReview.setShowsAllFiles(true, in: model)
        await settle(window)
        checkLanding(index: 3, host: host, model: model, context: "after asking for File03.swift again", check: check)
        ReviewRunProbe.clearTrace()
        await checkSettledDestination(model: model, host: host, window: window, check: check)
        await checkDefinitionNavigation(model: model, host: host, window: window, check: check)
        await checkFileTreeRestoration(model: model, check: check)
        check(!window.isVisible && !window.isKeyWindow, "navigation probe activated its window")
        window.contentView = nil
        withExtendedLifetime(app) {}
    }

    private static func checkFileTreeRestoration(model: WorkspaceModel, check: (Bool, String) -> Void) async {
        let key = "fileTree.expanded." + model.workspace.id.rawValue
        defer { UserDefaults.standard.removeObject(forKey: key) }
        do {
            let parent = model.workspace.path + "/Sources/Nested"
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try "let active = 1\n".write(toFile: parent + "/Active.swift", atomically: true, encoding: .utf8)
            await model.refreshFileTree(force: true)
            UserDefaults.standard.set(["Remembered", "Remembered/Child"], forKey: key)
            FileReview.openInNewTab(path: "Sources/Nested/Active.swift", in: model)
            check(FileReview.activePath(in: model) == "Sources/Nested/Active.swift", "file tree chose a different file than the active pinned tab")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: FileTreeView(model: model))
            await settle(window)
            let expanded = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
            check(expanded.isSuperset(of: ["Sources", "Sources/Nested", "Remembered", "Remembered/Child"]),
                  "opening the file tree did not reveal the active file or preserve previous folders")
            window.contentView = nil
            let notes = model.paneStores.center.showNotes(workspaceID: model.workspace.id)
            model.paneStores.tabs.reveal(.tool(notes.id), in: model)
            check(FileReview.activePath(in: model) == nil, "a hidden file tab was treated as active")
            window.contentView = NSHostingView(rootView: FileTreeView(model: model))
            await settle(window)
            check(Set(UserDefaults.standard.stringArray(forKey: key) ?? []) == expanded,
                  "opening the file tree without an active file lost its expanded folders")
            check(!window.isVisible && !window.isKeyWindow, "file tree probe activated its window")
            window.contentView = nil
        } catch { check(false, "file tree fixture failed: \(error)") }
    }

    private static func checkDefinitionNavigation(model: WorkspaceModel, host: NSView, window: NSWindow,
                                                  check: (Bool, String) -> Void) async {
        let destination = CodeLocation(path: "File06.swift", line: 19, column: 5)
        await FileReview.openFromDiff(destination, in: model, newTab: false)
        await settle(window)
        check(model.paneStores.center.review(for: model.workspace.id)?.showsAllFiles == true, "definition left the all-files diff")
        if let text = textViews(in: host).first(where: { $0.string.hasPrefix("let file6Line18 =") }),
           let scroll = scrollView(in: host) {
            let rect = text.convert(text.bounds, to: scroll.contentView)
            check(rect.intersects(scroll.contentView.bounds), "definition token landed outside the visible diff")
            check(text.onDefinition != nil && text.onReferences != nil, "diff code has no definition or usage actions")
            let offset = (text.string as NSString).range(of: "file6Line18").location
            if let manager = text.layoutManager, let container = text.textContainer {
                let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: offset, length: 1), actualCharacterRange: nil)
                let glyph = manager.boundingRect(forGlyphRange: glyphs, in: container)
                let point = text.convert(NSPoint(x: glyph.midX + text.textContainerOrigin.x, y: glyph.midY + text.textContainerOrigin.y), to: nil)
                if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [.command, .shift],
                                                  timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: 1, pressure: 1) {
                    var clicked: (Int, Bool)?
                    text.onNavigateSymbol = { clicked = ($0, $1) }
                    text.mouseDown(with: event)
                    check(clicked?.1 == true && abs((clicked?.0 ?? -100) - offset) <= 1, "Cmd-Shift-click lost its diff offset or tab intent")
                    let titles = text.menu(for: event)?.items.map(\.title) ?? []
                    check(titles.contains("Go to Definition") && titles.contains("Find Usages"), "diff context menu lost navigation actions")
                }
            }
        } else {
            check(false, "definition target did not render as its own diff row: \(textViews(in: host).map { String($0.string.prefix(28)) }), request=\(String(describing: model.paneStores.sourceFile(model.workspace.path + "/File06.swift").diffRequest)), layouts=\(ReviewRunProbe.preparedLayouts), \(landingReport(index: 6, host: host, model: model))")
        }
        await FileReview.openFromDiff(destination, in: model, newTab: true)
        await settle(window)
        check(textViews(in: host).contains { $0.string.hasPrefix("let file6Line18 =") },
              "file 6 was no longer drawn after opening its definition in a source tab")
        check(model.paneStores.center.tabs(for: model.workspace.id).contains { $0.isPinnedToPath && $0.path == destination.path },
              "forced new-tab navigation reused the diff")
        let outside = CodeLocation(path: "Outside.swift", line: 2, column: 5)
        do {
            try "// outside the loaded diff\nlet outside = 1\n".write(toFile: model.workspace.path + "/Outside.swift", atomically: true, encoding: .utf8)
            await FileReview.openFromDiff(outside, in: model, newTab: false)
            check(model.paneStores.center.tabs(for: model.workspace.id).contains { $0.isPinnedToPath && $0.path == outside.path },
                  "a definition outside the diff did not open a new tab")
            check(model.paneStores.sourceFile(model.workspace.path + "/Outside.swift").request == outside,
                  "new-tab navigation lost the destination position")
        } catch { check(false, "could not create the outside-diff fixture: \(error)") }
    }

    /// An agent editing files while the reader sits on a destination used to pull the view back
    /// to it on every changes poll, which on a real branch bounced between two files for seconds.
    private static func checkSettledDestination(model: WorkspaceModel, host: NSView, window: NSWindow,
                                                check: (Bool, String) -> Void) async {
        try? await Task.sleep(for: .milliseconds(1500))
        guard let scroll = scrollView(in: host), let text = firstLine(index: 3, in: host) else {
            check(false, "settled destination fixture is missing its views")
            return
        }
        let landed = scroll.contentView.bounds.origin.y
        text.scrollToVisible(NSRect(x: 0, y: 900, width: 10, height: 18))
        await settle(window)
        let reading = scroll.contentView.bounds.origin.y
        check(reading > landed + 100, "a settled destination pulled the review back from \(reading) to \(landed)")
        do {
            let path = model.workspace.path + "/File05.swift"
            let body = try String(contentsOfFile: path, encoding: .utf8)
            try (body + "let file5Appended = 1\nlet file5AppendedAgain = 2\n").write(toFile: path, atomically: true, encoding: .utf8)
        } catch { check(false, "could not edit the settled destination fixture: \(error)") }
        await model.refreshChanges()
        await settle(window)
        check(abs(scroll.contentView.bounds.origin.y - reading) < 2,
              "a changes refresh pulled a settled review from \(reading) to \(scroll.contentView.bounds.origin.y)")
    }

    private static func checkLanding(index: Int, host: NSView, model: WorkspaceModel, context: String,
                                     check: (Bool, String) -> Void) {
        guard let scroll = scrollView(in: host),
              let text = firstLine(index: index, in: host) else {
            check(false, "file \(index) did not render its first line \(context): \(landingReport(index: index, host: host, model: model))")
            return
        }
        let top = text.convert(text.bounds, to: scroll.contentView).minY - scroll.contentView.bounds.minY
        let header = InspectorLayout.reviewHeaderHeight
        let landed = top >= header - 1 && top <= header + 2 * CodeMetrics.rowHeight
        check(landed, landed ? "" : "file \(index) landed with its first line at \(top), expected just below header \(header), "
            + "\(context): \(landingReport(index: index, host: host, model: model))")
    }

    /// Enough to tell the three ways a landing goes wrong apart from one CI log: the scroller clamped
    /// at an end, a scroll that was requested and landed on a lazy stack's estimate (the target
    /// estimate and the realised positions disagree, and the trace shows the request), and a
    /// destination that was released or never asked for (the trace shows no request).
    ///
    /// The estimate adds each earlier file's prepared height and its header. A file never prepared
    /// counts as nothing and one prepared at another width is marked stale, so the estimate is only
    /// a lower bound when either appears.
    private static func landingReport(index: Int, host: NSView, model: WorkspaceModel) -> String {
        guard let scroll = scrollView(in: host) else { return "no scroll view" }
        let offset = scroll.contentView.bounds.origin.y
        let viewport = scroll.contentView.bounds.height
        let document = scroll.documentView?.bounds.height ?? 0
        let limit = max(0, document - viewport)
        let clamped = offset >= limit - 1 ? "at the end" : offset <= 1 ? "at the top" : "no"
        let width = host.bounds.width
        let header = InspectorLayout.reviewHeaderHeight
        var estimate: CGFloat = 0
        var files: [String] = []
        for (position, file) in model.reviewFiles.enumerated() {
            let geometry = ReviewRunProbe.preparedGeometry[file.path]
            if position < index { estimate += header + (geometry?.height ?? 0) }
            let identity = file.id == file.path ? file.path : "\(file.path) id \(file.id)"
            let layout = geometry.map { "height \(Int($0.height)) at width \(Int($0.width))\(abs($0.width - width) > 0.5 ? " stale" : "")" }
            files.append("\(position) \(identity) \(layout ?? "never prepared")")
        }
        let realised = textViews(in: host).map { text in
            let name = text.string.dropFirst(4).prefix { $0 != " " }
            return "\(name) at \(Int(text.convert(text.bounds, to: scroll.contentView).minY))"
        }
        return "offset \(Int(offset)) of \(Int(limit)) (document \(Int(document)), viewport \(Int(viewport)), width \(Int(width)), "
            + "clamped \(clamped)); target estimate \(Int(estimate)); files [\(files.joined(separator: "; "))]; "
            + "realised [\(realised.joined(separator: ", "))]; \(sectionReport(host: host, scroll: scroll)); "
            + "trace [\(ReviewRunProbe.navigationTrace.joined(separator: " | "))]"
    }

    /// Which headers, sections and diff blocks the lazy stack has realised, against the visible rect.
    /// An empty viewport with no realised entry across it is a stretch the stack left unrealised; one
    /// with the target's blocks across it, flagged off and marked stale, is a block whose geometry
    /// callback did not run after a programmatic scroll. Capped, so a failure stays one readable line.
    private static func sectionReport(host: NSView, scroll: NSScrollView) -> String {
        let visible = scroll.contentView.bounds
        let codeFrames = textViews(in: host).map { $0.convert($0.bounds, to: scroll.contentView) }
        let realised = ReviewRunProbe.sections
            .filter { $0.value.appeared }
            .sorted { ($0.value.documentFrame?.minY ?? 0) < ($1.value.documentFrame?.minY ?? 0) }
        let entries = realised.prefix(30).map { entry -> String in
            let record = entry.value
            var line = "\(entry.key) \(record.documentFrame.map(span) ?? "no frame")"
            if let scrollFrame = record.scrollFrame, let documentFrame = record.documentFrame {
                let stale = abs(scrollFrame.minY + visible.minY - documentFrame.minY) > 1
                line += ", last visible-relative \(span(scrollFrame))\(stale ? " stale" : "")"
            }
            if let near = record.nearViewport {
                let drawn = record.documentFrame.map { frame in codeFrames.contains { $0.intersects(frame) } } ?? false
                line += ", near \(near ? "yes" : "no"), code \(drawn ? "yes" : "no")"
            }
            return line
        }
        return "visible \(span(visible)); sections \(realised.count) [\(entries.joined(separator: "; "))]"
    }

    private static func span(_ rect: CGRect) -> String {
        "\(Int(rect.minY))..\(Int(rect.maxY))"
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
        let input = inputView(in: host), scroll = scrollView(in: host), text = firstLine(index: 3, in: host)
        guard let input, let scroll, let text,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                          characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                                          keyCode: 125) else {
            let missing = [input == nil ? "input observer" : nil, scroll == nil ? "scroll view" : nil,
                           text == nil ? "file 3's first line" : nil].compactMap { $0 }
            check(false, "keyboard navigation fixture is missing its views: \(missing.isEmpty ? "key event" : missing.joined(separator: ", "))")
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

    /// Records each offset the scroller moves to between the review's own trace entries, so a
    /// failure shows where each scroll request actually put the document.
    private static func settle(_ window: NSWindow) async {
        var last: CGFloat?
        for _ in 0..<30 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let view = window.contentView, let scroll = scrollView(in: view) {
                let offset = scroll.contentView.bounds.origin.y
                if last.map({ abs($0 - offset) > 0.5 }) ?? true { ReviewRunProbe.trace("offset \(Int(offset))") }
                last = offset
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    private struct Fixture: View {
        let model: WorkspaceModel

        var body: some View {
            if let tab = model.paneStores.center.review(for: model.workspace.id) {
                AllFilesReviewView(model: model, selectedPath: tab.path,
                                   navigationRevision: tab.reviewNavigationRevision)
            }
        }
    }
}
#endif
