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
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }

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
        let result: JSONValue = .object([
            "checks": .integer(checks), "passed": .bool(failures.isEmpty), "failures": .strings(failures),
        ])
        if let data = try? JSONEncoder().encode(result) { FileHandle.standardOutput.write(data) }
        exit(failures.isEmpty ? 0 : 1)
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
