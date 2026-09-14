import AppKit
import SwiftUI
import BloomCore

#if DEBUG
@MainActor
enum ReviewWrappingProbe {
    static func run(check: (Bool, String) -> Void, save: (NSView, String) -> Void) async {
        checkKeyboardAndMenu(check: check)
        for split in [false, true] {
            let host = NSHostingView(rootView: Fixture(width: 640, split: split))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            for width: CGFloat in [640, 320, 500] {
                window.setContentSize(NSSize(width: width, height: 600))
                host.rootView = Fixture(width: width, split: split)
                for _ in 0..<4 {
                    host.layoutSubtreeIfNeeded()
                    try? await Task.sleep(for: .milliseconds(30))
                }
                let views = textViews(in: host)
                check(views.count == (split ? 2 : 1), "wrapped code view was not rendered")
                for view in views {
                    let lines = view.string.components(separatedBy: "\n")
                    let expected = Fixture.texts.map { $0 ?? "" }.joined(separator: "\n")
                    let opposite = Fixture.opposite.map { $0 ?? "" }.joined(separator: "\n")
                    check(view.string.utf8.elementsEqual(expected.utf8) || view.string.utf8.elementsEqual(opposite.utf8),
                          "wrapping changed the source text")
                    guard let manager = view.layoutManager, let container = view.textContainer else {
                        check(false, "wrapped code has no text layout")
                        continue
                    }
                    manager.ensureLayout(for: container)
                    check(manager.usedRect(for: container).width <= container.containerSize.width + 1,
                          "wrapped code exceeded its column")
                    var offset = 0
                    var expectedY: CGFloat = 0
                    for (index, line) in lines.enumerated() where offset < view.string.utf16.count {
                        let glyph = manager.glyphIndexForCharacter(at: offset)
                        let y = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                        check(abs(y - expectedY) < 1,
                              "wrapped source row \(index) started at \(y), expected \(expectedY)")
                        expectedY += view.rowHeights[index]
                        offset += line.utf16.count + 1
                    }
                    if width == 640 { view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count)) }
                    check(view.selectedRange().length == view.string.utf16.count,
                          "resizing wrapped code lost its selection")
                }
                save(host, "wrapped-\(split ? "split" : "unified")-\(Int(width))")
            }
            check(!window.isVisible && !window.isKeyWindow, "wrapping probe activated its window")
            window.contentView = nil
        }
    }

    private static func checkKeyboardAndMenu(check: (Bool, String) -> Void) {
        let view = WrappedDiffChrome.ChromeView(frame: NSRect(x: 0, y: 0, width: 320, height: 90))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.heights = [54, 18, 18]
        view.commentable = [true, false, true]
        view.editableRows = [true, false, true]
        var commented: [Int] = []
        view.onComment = { commented.append($0) }
        check(window.makeFirstResponder(view), "wrapped gutter cannot receive keyboard focus")
        func key(_ code: UInt16) {
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, characters: "", charactersIgnoringModifiers: "",
                                           isARepeat: false, keyCode: code) { view.keyDown(with: event) }
        }
        key(125)
        key(36)
        key(126)
        key(49)
        check(commented == [2, 0], "keyboard comments did not skip empty wrapped rows")
        if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 5, y: 85),
                                         modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
           let menu = view.menu(for: event) {
            view.onComment = { _ in commented.append(99) }
            menu.performActionForItem(at: 0)
            check(commented == [2, 0, 0], "native menu changed its anchor after a refresh")
        } else { check(false, "wrapped gutter offered no comment menu") }
        key(125)
        view.commentable = [true]
        view.heights = [18]
        view.onComment = { commented.append($0) }
        key(36)
        check(commented.last == 0, "keyboard focus retained a row removed by a diff refresh")
        window.contentView = nil
    }

    private static func textViews(in view: NSView) -> [WrappedCodeText.TextView] {
        if let text = view as? WrappedCodeText.TextView { return [text] }
        return view.subviews.flatMap { textViews(in: $0) }
    }

    private struct Fixture: View {
        var width: CGFloat
        var split: Bool
        static let texts: [String?] = [
            "let message = \"" + String(repeating: "a longer piece of code ", count: 10) + "\"",
            nil,
            "let unicode = \"café 👩🏽‍💻 漢字\"",
            "\tlet values = [" + String(repeating: "12345, ", count: 16) + "]",
            "return result",
            // Cache the longer encoding first to catch attributes extending past the shorter one.
            "// cafe\u{301}",
            "// caf\u{e9}",
        ]
        static let opposite: [String?] = [
            "let message = input", "// The other half contains a line here.",
            String(repeating: "// another longer comment ", count: 12), nil, "return newResult", nil, nil,
        ]

        var body: some View {
            let half = (width - Metrics.hairline) / 2
            let codeWidth = floor(max(1, (split ? half : width)
                - DiffGutter.width(for: split ? .old : .both) - CodeMetrics.markerWidth - CodeMetrics.gutterPadding))
            let own = Self.texts.map { WrappedCodeLayout.height(of: $0 ?? "", width: codeWidth) }
            let other = Self.opposite.map { WrappedCodeLayout.height(of: $0 ?? "", width: codeWidth) }
            let heights = split ? zip(own, other).map { max($0, $1) } : own
            ScrollView(.vertical) {
                if split {
                    HStack(spacing: 0) {
                        run(Self.texts, width: half, heights: heights, numbers: .old)
                        Hairline(axis: .vertical)
                        run(Self.opposite, width: half, heights: heights, numbers: .new)
                    }
                } else {
                    run(Self.texts, width: width, heights: heights, numbers: .both)
                }
            }
            .defaultScrollAnchor(.topLeading)
            .background(Palette.surface)
        }

        private func run(_ texts: [String?], width: CGFloat, heights: [CGFloat], numbers: DiffGutter.Numbers) -> some View {
            DiffRunView(
                lines: texts.enumerated().map { index, text in
                    DiffRunLine(line: text.map {
                        DiffLine(kind: .addition, text: $0, oldNumber: index + 1, newNumber: index + 1, index: index)
                    })
                },
                language: .swift, numbers: numbers, width: width, wrappedHeights: heights,
                onComment: { _ in }, onDragComment: { _, _ in }, onEndCommentDrag: {}, onEdit: { _ in }
            )
        }
    }
}
#endif
