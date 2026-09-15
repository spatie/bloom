import AppKit
import SwiftUI

#if DEBUG
/// Exercise the production text views without showing a window or posting mouse/key events.
@MainActor
enum TranscriptSelectionProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--transcript-selection-probe") }

    static func runAndExit() -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { await run() }
        RunLoop.main.run()
        exit(1)
    }

    private static func run() async {
        let sample = """
        First paragraph with 🌱 and **bold words**.

        Second paragraph with a [link](https://example.com).

        - First list item
        - Second list item

        ```swift
        let answer = 42
        print(answer)
        ```

        | Name | Value |
        | --- | --- |
        | Example | Forty two |

        Final paragraph.
        """
        var failures: [String] = []
        var checks = 0
        func check(_ passed: Bool, _ message: String) {
            checks += 1
            if !passed { failures.append(message) }
        }
        let controller = NSHostingController(rootView:
            VStack(alignment: .leading) {
                MarkdownView(sample)
                MarkdownView("A separate answer.")
            }.frame(width: 620, alignment: .leading)
        )
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 1800),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentViewController = controller
        try? await Task.sleep(for: .milliseconds(100))
        let host = controller.view
        let size = controller.sizeThatFits(in: CGSize(width: 620, height: 10_000))
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded()
        let all = textViews(in: host)
        if let first = all.first(where: { $0.string.hasPrefix("First paragraph") }),
           let selection = first.answerSelection,
           let other = all.first(where: { $0.string == "A separate answer." }) {
            let views = selection.orderedViews
            check(views.count == 10, "not every paragraph, list item, code block and table cell joined the answer")
            check(views.last?.string == "Final paragraph.", "reading order did not end with the final paragraph")
            check(views.contains { $0.string == "let answer = 42\nprint(answer)" }, "code text was missing")
            first.selectAll(nil)
            check(selection.selectedText == sample, "Select All did not copy the complete source")
            check(views.allSatisfy { $0.selectedRange().length == $0.string.utf16.count }, "Select All left an unselected block")
            check(other.selectedRange().length == 0, "Select All escaped into another answer")
            if let last = views.last {
                selection.begin(in: first, offset: 6, extending: false)
                selection.extend(to: last, offset: 5)
                check(first.selectedRange().location == 6, "forward selection lost its starting offset")
                check(last.selectedRange().length == 5, "forward selection lost its ending offset")
                check(selection.selectedText.hasPrefix("paragraph"), "partial copy included unselected text")
                check(selection.selectedText.contains("• First list item"), "partial copy lost the list marker")
                check(selection.selectedText.contains("Name\tValue\nExample\tForty two"), "partial copy lost table cell boundaries")
                let forward = selection.selectedText
                selection.begin(in: last, offset: 5, extending: false)
                selection.extend(to: first, offset: 6)
                check(selection.selectedText == forward, "backward selection copied different text")
                let board = NSPasteboard.withUniqueName()
                board.declareTypes([.string], owner: nil)
                let copied = first.writeSelection(to: board, type: .string)
                check(copied && board.string(forType: .string) == forward, "clipboard export lost cross-block text")
                board.releaseGlobally()
                first.setSelectedRange(NSRange(location: 0, length: 5))
                check(last.selectedRange().length == 0, "native selection retained stale blocks")
                check(selection.selectedText == "First", "native selection copied stale Select All text")
            }
        } else {
            check(false, "production text views or their selection scopes were missing")
        }
        check(!window.isVisible, "the probe displayed a window")
        let result: [String: Any] = ["checks": checks, "failures": failures, "passed": failures.isEmpty]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(data)
        }
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func textViews(in view: NSView) -> [LinkTextView] {
        (view as? LinkTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }
}
#endif
