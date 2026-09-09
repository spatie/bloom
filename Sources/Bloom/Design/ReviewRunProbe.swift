import AppKit
import BloomCore
import Observation
import SwiftUI

#if DEBUG
/// Checks the real diff controls in an invisible window without opening the app or its database.
@MainActor
enum ReviewRunProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--review-run-probe") }

    static func runAndExit() -> Never {
        guard Bundle.main.bundleIdentifier == "be.spatie.bloom.review-probe" else { exit(1) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { await run() }
        RunLoop.main.run()
        exit(1)
    }

    private static func run() async {
        var failures: [String] = []
        var checks = 0
        var scrollSteps: [Double] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }

        progress("Checking comment scrolling and focus")
        for numbers in [DiffGutter.Numbers.both, .old, .new] {
            let fixture = ReviewRunFixture()
            let host = NSHostingView(rootView: ReviewRunFixtureView(fixture: fixture, numbers: numbers))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = host
            await settle(window)
            guard let scroll = scrollView(in: host) else {
                check(false, "diff has no scroll view")
                continue
            }

            for line in [1, 200, 380, 10] {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(line - 1) * CodeMetrics.rowHeight))
                scroll.reflectScrolledClipView(scroll.contentView)
                await settle(window)
                hoverViews(in: host).first?.onChange?(line - 1)
                await settle(window)
                save(host, name: "\(numbers)-\(line)")
                let height = scroll.documentView?.bounds.height ?? 0
                check(abs(height - CodeMetrics.rowHeight * 400) < 1,
                      "diff changed height while scrolling")
            }
            fixture.commentLine = 10
            fixture.text = "Review text survives scrolling"
            await settle(window)
            save(host, name: "\(numbers)-editor")
            check(textView(in: host)?.string == fixture.text, "comment text was not drawn")
            check(window.firstResponder === textView(in: host), "comment did not receive focus")
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CodeMetrics.rowHeight * 350))
            scroll.reflectScrolledClipView(scroll.contentView)
            await settle(window)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CodeMetrics.rowHeight * 9))
            scroll.reflectScrolledClipView(scroll.contentView)
            await settle(window)
            check(textView(in: host)?.string == fixture.text, "comment text was lost after scrolling away")
            check(!window.isVisible && !window.isKeyWindow, "probe showed or activated its window")
            window.contentView = nil
        }
        // Use the same nested scrollers as all-files review. A lazy stack inside the
        // horizontal scroller previously realised the whole file's text and controls.
        var realisedRuns: [String: JSONValue] = [:]
        progress("Checking wrapped code")
        await ReviewWrappingProbe.run(check: check, save: { save($0, name: $1) })
        progress("Checking embedded scrolling")
        let compareEager = CommandLine.arguments.contains("--review-compare-eager")
        for deferred in compareEager ? [false, true] : [true] {
            let host = NSHostingView(rootView: EmbeddedReviewFixture(deferred: deferred))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = host
            await settle(window)
            if let scroll = scrollView(in: host) {
                let initial = hoverViews(in: host).count
                // Classic scrollbars add height around the horizontal scroller on CI.
                // The code keeps its exact height; the outer extent must stay stable.
                let initialHeight = scroll.documentView?.bounds.height ?? 0
                let inner = scroll.documentView.flatMap { scrollView(in: $0) }
                let codeHeight = inner?.documentView?.bounds.height ?? 0
                check(abs(codeHeight - CodeMetrics.rowHeight * 5000) < 1,
                      "embedded code height was \(codeHeight), expected \(CodeMetrics.rowHeight * 5000)")
                realisedRuns[deferred ? "deferred" : "eager"] = .integer(initial)
                check(deferred ? (1...2).contains(initial) : initial == 13,
                      "unexpected number of realised text runs: \(initial), deferred: \(deferred)")
                for line in [1, 2400, 4900, 10] {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(line - 1) * CodeMetrics.rowHeight))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    await settle(window)
                    let height = scroll.documentView?.bounds.height ?? 0
                    check(abs(height - initialHeight) < 1,
                          "embedded diff height moved from \(initialHeight) to \(height)")
                    if deferred {
                        check((1...2).contains(hoverViews(in: host).count),
                              "embedded diff did not keep rendering bounded at line \(line)")
                        save(host, name: "embedded-\(line)")
                    }
                }
                check(!window.isVisible && !window.isKeyWindow, "embedded probe activated its window")
            } else {
                check(false, "embedded diff has no vertical scroll view")
            }
            window.contentView = nil
        }
        progress("Checking complete review layouts and collapse")
        if let directory = ProbeHarness.value(for: "--review-run-probe") {
            let app = AppModel()
            let model = WorkspaceModel(
                workspace: Workspace(repoID: .new(), name: "Review", branch: "main",
                                     path: directory + "/fixture", baseBranch: "main"),
                app: app
            )
            await model.refreshChanges()
            check(model.changedFiles.count == 6, "review fixture did not load its six changed files")
            model.selectedFilePath = "README.md"
            FileReview.setShowsAllFiles(true, in: model)
            check(CenterTabStore.shared.review(for: model.workspace.id)?.showsAllFiles == true,
                  "review-all toggle did not activate all-files mode")
            FileReview.setShowsAllFiles(false, in: model)
            check(CenterTabStore.shared.review(for: model.workspace.id)?.showsAllFiles == false,
                  "review-all toggle did not return to one file")
            check(CenterTabStore.shared.review(for: model.workspace.id)?.path == "README.md",
                  "review-all toggle forgot the selected file")
            let inspector = NSHostingView(rootView: ChangedFileList(model: model).background(Palette.surface))
            let inspectorWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 560),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            inspectorWindow.contentView = inspector
            await settle(inspectorWindow)
            save(inspector, name: "review-toggle-off")
            FileReview.setShowsAllFiles(true, in: model)
            await settle(inspectorWindow)
            save(inspector, name: "review-toggle-on")
            FileReview.open(path: model.changedFiles.first?.path ?? "", in: model)
            let host = NSHostingView(rootView: LinkedReviewFixture(model: model))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = host
            // Let the per-file git reads land, including files newly exposed by shorter diffs.
            for _ in 0..<10 { await settle(window) }
            save(host, name: "all-files-light")
            window.appearance = NSAppearance(named: .darkAqua)
            await settle(window)
            save(host, name: "all-files-dark")
            window.appearance = NSAppearance(named: .aqua)
            window.setContentSize(NSSize(width: 500, height: 680))
            await settle(window)
            save(host, name: "all-files-narrow")
            window.setContentSize(NSSize(width: 320, height: 680))
            await settle(window)
            save(host, name: "all-files-compact")
            window.setContentSize(NSSize(width: 1000, height: 680))
            await settle(window)
            UserDefaults.standard.set(true, forKey: DiffLayoutSetting.storageKey)
            await settle(window)
            save(host, name: "all-files-split")
            UserDefaults.standard.set(false, forKey: DiffLayoutSetting.storageKey)
            model.selectedFilePath = "Sources/Checkout.swift"
            FileReview.open(path: "Sources/Checkout.swift", in: model)
            for _ in 0..<5 { await settle(window) }
            save(host, name: "all-files-jump")
            model.selectedFilePath = "Sources/LongReview.swift"
            FileReview.open(path: "Sources/LongReview.swift", in: model)
            for _ in 0..<5 { await settle(window) }
            if let scroll = scrollView(in: host) {
                let origin = scroll.contentView.bounds.origin
                scroll.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + 300))
                scroll.reflectScrolledClipView(scroll.contentView)
                await settle(window)
                save(host, name: "all-files-sticky")
                let revision = CenterTabStore.shared.review(for: model.workspace.id)?.reviewNavigationRevision
                check(model.selectedFilePath == "Sources/LongReview.swift", "inspector selection did not follow the sticky file")
                check(FileReview.currentPath(in: model) == model.selectedFilePath,
                      "review did not remember the file reached by scrolling")
                if let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                       wheelCount: 1, wheel1: 100_000, wheel2: 0, wheel3: 0),
                   let event = NSEvent(cgEvent: wheel) {
                    scroll.scrollWheel(with: event)
                }
                await settle(window)
                check(model.selectedFilePath == model.changedFiles.first?.path, "scrolling upwards selected \(model.selectedFilePath ?? "nil") at \(scroll.contentView.bounds.origin.y)")
                check(CenterTabStore.shared.review(for: model.workspace.id)?.reviewNavigationRevision == revision,
                      "scroll-follow issued another navigation request")
                if CommandLine.arguments.contains("--review-scroll-profile") {
                    progress("Profiling continuous scroll")
                    let bottom = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                    for step in 0..<240 {
                        let start = ProcessInfo.processInfo.systemUptime
                        let fraction = CGFloat(step < 120 ? step : 239 - step) / 119
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom * fraction))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        host.layoutSubtreeIfNeeded()
                        try? await Task.sleep(for: .milliseconds(16))
                        scrollSteps.append(ProcessInfo.processInfo.systemUptime - start)
                    }
                }
            }
            check(!hoverViews(in: host).isEmpty, "review did not render code after jumping to a file")
            check(!window.isVisible && !window.isKeyWindow, "review probe activated its window")
            window.contentView = nil
            if let file = model.changedFiles.first {
                let section = NSHostingView(rootView: ReviewCollapseFixture(model: model, file: file))
                window.contentView = section
                await settle(window)
                check(!hoverViews(in: section).isEmpty, "expanded file did not render its code")
                section.rootView = ReviewCollapseFixture(model: model, file: file, collapsed: true)
                await settle(window)
                check(hoverViews(in: section).isEmpty, "collapsed file kept its code views alive")
                let height = scrollView(in: section)?.documentView?.bounds.height ?? 0
                check(abs(height - 40) < 1, "collapsed file did not shrink to its header")
                save(section, name: "all-files-collapsed")
                section.rootView = ReviewCollapseFixture(model: model, file: file)
                for _ in 0..<5 { await settle(window) }
                check(!hoverViews(in: section).isEmpty, "reopened file stayed on its loading placeholder")
                window.contentView = nil
            }
            if let file = model.changedFiles.first(where: { $0.path == "Sources/Checkout.swift" }) {
                model.forgetHeldDiff(for: file.path)
                let whitespaceHost = NSHostingView(rootView: DiffView(model: model, file: file))
                window.contentView = whitespaceHost
                window.contentView?.layoutSubtreeIfNeeded()
                await Task.yield()
                UserDefaults.standard.set(true, forKey: DiffWhitespaceSetting.storageKey)
                for _ in 0..<8 { await settle(window) }
                let raw = DiffDocument.parse(patch: await model.patch(for: file), path: file.path)
                let held = model.heldDiff(for: file, ignoringWhitespace: true)
                check(held != nil && raw != nil && held?.document.file == raw?.ignoringWhitespace(),
                      "whitespace change during loading cached the wrong presentation")
                UserDefaults.standard.set(false, forKey: DiffWhitespaceSetting.storageKey)
                window.contentView = nil
            }
            inspectorWindow.contentView = nil
            withExtendedLifetime(app) {}
        }
        let result: JSONValue = .object([
            "scrollStepP95Microseconds": .integer(scrollSteps.isEmpty ? 0
                : Int(scrollSteps.sorted()[Int(Double(scrollSteps.count - 1) * 0.95)] * 1_000_000)),
            "realisedRuns": .object(realisedRuns),
            "checks": .integer(checks), "passed": .bool(failures.isEmpty), "failures": .strings(failures),
        ])
        if let data = try? JSONEncoder().encode(result) { FileHandle.standardOutput.write(data) }
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func progress(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func settle(_ window: NSWindow) async {
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private static func save(_ host: NSView, name: String) {
        guard let directory = ProbeHarness.value(for: "--review-run-probe"),
              let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }

    private static func textView(in view: NSView) -> ComposerTextView? {
        if let text = view as? ComposerTextView { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }

    private static func hoverViews(in view: NSView) -> [DiffRowHover.RowHoverView] {
        if let hover = view as? DiffRowHover.RowHoverView { return [hover] }
        return view.subviews.flatMap { hoverViews(in: $0) }
    }

}

private struct LinkedReviewFixture: View {
    let model: WorkspaceModel

    var body: some View {
        if let tab = CenterTabStore.shared.review(for: model.workspace.id) {
            ReviewPaneView(model: model, tab: tab)
        }
    }
}

private struct ReviewCollapseFixture: View {
    let model: WorkspaceModel
    let file: ChangedFile
    var collapsed = false

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                DiffView(model: model, file: file, embeddedWidth: 1000, embeddedViewportHeight: 680,
                         isCollapsed: collapsed, onToggleCollapsed: {})
            }
        }
        .defaultScrollAnchor(.topLeading)
    }
}

private struct EmbeddedReviewFixture: View {
    let deferred: Bool

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        ForEach(Array(stride(from: 0, to: 5000, by: 400)), id: \.self) { start in
                            let count = min(400, 5000 - start)
                            if deferred {
                                ReviewDiffBlock(height: CGFloat(count) * CodeMetrics.rowHeight,
                                                viewportHeight: 600) {
                                    run(start: start, count: count)
                                }
                            } else {
                                run(start: start, count: count)
                            }
                        }
                    }
                    .frame(width: 1400)
                }
                .fixedSize(horizontal: false, vertical: true)
                .defaultScrollAnchor(.topLeading)
            }
        }
        .defaultScrollAnchor(.topLeading)
    }

    private func run(start: Int, count: Int) -> some View {
        DiffRunView(
            lines: (start..<(start + count)).map { line in
                DiffRunLine(line: DiffLine(
                    kind: .addition, text: "let value\(line) = input",
                    oldNumber: nil, newNumber: line + 1, index: line
                ))
            },
            language: .swift, width: 1400,
            onComment: { _ in }, onDragComment: { _, _ in }, onEndCommentDrag: {}, onEdit: { _ in }
        ).equatable()
    }
}

@MainActor
@Observable
private final class ReviewRunFixture {
    var commentLine: Int?
    var text = ""
}

private struct ReviewRunFixtureView: View {
    let fixture: ReviewRunFixture
    var numbers: DiffGutter.Numbers

    private var ranges: [Range<Int>] {
        guard let line = fixture.commentLine else { return [1..<401] }
        return [1..<(line + 1), (line + 1)..<401].filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(ranges, id: \.lowerBound) { range in
                    DiffRunView(
                        lines: range.map { line in
                            DiffRunLine(line: DiffLine(
                                kind: numbers == .old ? .deletion : .addition,
                                text: "let value\(line) = input", oldNumber: line, newNumber: line, index: line
                            ))
                        },
                        language: .swift, numbers: numbers, width: 760,
                        onComment: { fixture.commentLine = $0.line },
                        onDragComment: { _, _ in }, onEndCommentDrag: {}, onEdit: { _ in }
                    ).equatable()
                    if fixture.commentLine == range.upperBound - 1 {
                        ReviewCommentEditorView(
                            text: Binding(get: { fixture.text }, set: { fixture.text = $0 }), width: 760,
                            onCommit: { fixture.commentLine = nil }, onCancel: { fixture.commentLine = nil }
                        )
                    }
                }
            }
        }
    }
}
#endif
