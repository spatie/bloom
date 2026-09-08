import AppKit
import BloomCore
import SwiftUI
import MarkdownEngine

#if DEBUG
/// Runs notification callbacks and draws the welcome and tab controls in an isolated probe bundle.
@MainActor
enum AppChromeProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--app-chrome-probe") }

    static func runAndExit() -> Never {
        guard Bundle.main.bundleIdentifier != "be.spatie.bloom",
              ProcessInfo.processInfo.environment["BLOOM_DB_PATH"] != nil else { exit(1) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { await run() }
        RunLoop.main.run()
        exit(1)
    }

    private static func run() async {
        let availability = TextZoomAvailability.shared
        let oldSize = ChatTextSize.current
        var failures: [String] = []
        for size in ChatTextSize.allCases {
            ChatTextSize.current = size
            for _ in 0..<100 {
                NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: nil)
            }
            await Task.detached {
                for _ in 0..<100 {
                    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
                }
            }.value
            try? await Task.sleep(for: .milliseconds(50))
            if availability.canZoomIn != (size.stepped(by: 1) != nil) { failures.append("zoom in: \(size)") }
            if availability.canZoomOut != (size.stepped(by: -1) != nil) { failures.append("zoom out: \(size)") }
            if availability.canResetSize != (size != .defaultChoice) { failures.append("reset: \(size)") }
        }
        ChatTextSize.current = oldSize
        await render(ChromeTabsFixture(), size: CGSize(width: 720, height: 96), name: "tabs")
        await render(WelcomeGreeting(isFirstVisit: false, continueTitle: "See what Bloom needs", onContinue: {}),
                     size: CGSize(width: 520, height: 424), name: "welcome-inactive")
        let emptyAligned = await render(NotesPageFixture(), size: CGSize(width: 960, height: 680), name: "notes-empty")
        let narrowAligned = await render(NotesPageFixture(body: "Remember to keep the launch page concise.\n\nDecisions\nUse the current colours and retain the product screenshots.\n\nNext steps\nReview the mobile layout and check the signup flow."),
                     size: CGSize(width: 360, height: 540), name: "notes-narrow")
        if !emptyAligned { failures.append("empty notes caret and placeholder do not align") }
        if !narrowAligned { failures.append("narrow notes text does not align") }
        let formatting = await checkFormatting()
        failures += formatting.failures
        let result: [String: Any] = ["notifications": 1000, "checks": 17 + formatting.checks, "passed": failures.isEmpty, "failures": failures]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(data)
        }
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func checkFormatting() async -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        let original = "Hello 👩🏽‍💻 café\nsecond line"
        var note = original
        let editor = NativeTextViewWrapper(text: Binding(get: { note }, set: { note = $0 }),
                                           documentId: "formatting-probe")
        let controller = NotesEditorController(rootView: editor)
        controller.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.frame = CGRect(x: 0, y: 0, width: 640, height: 240)
        controller.view.layoutSubtreeIfNeeded()
        controller.scheduleConnection()
        try? await Task.sleep(for: .milliseconds(150))
        guard let text = controller.textView else { return (1, ["Markdown editor did not connect"]) }
        let selected = (original as NSString).range(of: "👩🏽‍💻 café")
        text.setSelectedRange(selected)
        controller.apply(.bold)
        try? await Task.sleep(for: .milliseconds(100))
        check(note == "Hello **👩🏽‍💻 café**\nsecond line", "bold lost or changed the selected Unicode text")
        check((text.string as NSString).substring(with: text.selectedRange()) == "👩🏽‍💻 café", "bold lost the selection")
        text.undoManager?.undo()
        try? await Task.sleep(for: .milliseconds(100))
        check(note == original, "formatting did not undo in one step: binding=\(note.debugDescription), native=\(text.string.debugDescription)")
        text.undoManager?.redo()
        try? await Task.sleep(for: .milliseconds(100))
        check(note == "Hello **👩🏽‍💻 café**\nsecond line", "formatting did not redo")
        text.undoManager?.undo()
        try? await Task.sleep(for: .milliseconds(100))
        text.setSelectedRange(NSRange(location: 0, length: (text.string as NSString).length))
        controller.apply(.codeBlock)
        try? await Task.sleep(for: .milliseconds(100))
        check(note == "```\n\(original)\n```", "code formatting discarded the selected lines")
        text.undoManager?.undo()
        try? await Task.sleep(for: .milliseconds(100))
        check(note == original, "code formatting did not undo in one step")
        text.setSelectedRange(NSRange(location: 0, length: (text.string as NSString).length))
        controller.apply(.bulletList)
        try? await Task.sleep(for: .milliseconds(100))
        check(note == "- Hello 👩🏽‍💻 café\n- second line", "list formatting lost a line")
        text.undoManager?.undo()
        try? await Task.sleep(for: .milliseconds(100))
        check(note == original, "list formatting did not undo in one step")
        text.insertText("!", replacementRange: NSRange(location: (text.string as NSString).length, length: 0))
        try? await Task.sleep(for: .milliseconds(100))
        text.setSelectedRange(NSRange(location: 0, length: 5))
        controller.apply(.bold)
        try? await Task.sleep(for: .milliseconds(100))
        text.insertText("?", replacementRange: NSRange(location: (text.string as NSString).length, length: 0))
        try? await Task.sleep(for: .milliseconds(100))
        text.undoManager?.undo()
        try? await Task.sleep(for: .milliseconds(100))
        check(note == "**Hello** 👩🏽‍💻 café\nsecond line!", "undoing later typing also removed formatting")
        text.undoManager?.undo()
        try? await Task.sleep(for: .milliseconds(100))
        check(note == original + "!", "undoing formatting also removed earlier typing")
        text.undoManager?.undo()
        try? await Task.sleep(for: .milliseconds(100))
        check(note == original, "earlier typing was not independently undoable")
        check(!window.isVisible, "the Markdown probe displayed a window")
        controller.disconnect()
        return (checks, failures)
    }

    private static func textView(in root: NSView) -> NSTextView? {
        if let view = root as? NSTextView { return view }
        return root.subviews.lazy.compactMap { textView(in: $0) }.first
    }

    @discardableResult
    private static func render(_ content: some View, size: CGSize, name: String) async -> Bool {
        let host = NSHostingController(rootView: content
            .environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .inactive)
            .transaction { $0.disablesAnimations = true }
            .frame(width: size.width, height: size.height)
            .background(Palette.sidebar))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = host
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(150))
        host.view.displayIfNeeded()
        var aligned = true
        if name.hasPrefix("notes") {
            if let editor = textView(in: host.view) {
                aligned = editor.textContainerOrigin.y == 0
                    && editor.textContainerOrigin.x + (editor.textContainer?.lineFragmentPadding ?? 0) == NotesPage.textPadding
            } else { aligned = false }
        }
        guard let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }
        if host.view.isFlipped {
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: 1, y: -1)
        }
        host.view.layer?.render(in: context.cgContext)
        context.flushGraphics()
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: "/tmp/bloom-chrome-\(name).png"))
        return aligned
    }
}

private struct ChromeTabsFixture: View {
    var body: some View {
        VStack(spacing: 16) {
            ChromeTabsRow(busy: false)
            ChromeTabsRow(busy: true)
        }
        .padding(.horizontal, 8)
    }
}

private struct ChromeTabsRow: View {
    var busy: Bool
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            tab("Chat", icon: "bubble.left", active: true, busy: busy)
            tab("All changes", icon: "doc.text")
            TabStripSeparator()
            tab("Terminal", icon: "terminal")
            Spacer(minLength: 0)
        }
        .frame(height: Metrics.barHeight)
    }

    private func tab(_ title: String, icon: String, active: Bool = false, busy: Bool = false) -> some View {
        TabItemView(title: title, icon: .symbol(icon), isActive: active, isRunning: busy,
                    isRenaming: false, editableTitle: title, canClose: true, closeTitle: "Close tab",
                    onSelect: {}, onStartRename: {}, onCommitRename: { _ in }, onCancelRename: {}, onClose: {},
                    namespace: namespace)
            .fixedSize(horizontal: true, vertical: false)
    }
}
private struct NotesPageFixture: View {
    @State private var text: String
    @FocusState private var isEditing: Bool

    init(body: String = "") { _text = State(initialValue: body) }

    var body: some View {
        NotesPage(text: $text, isEditing: $isEditing, workspaceID: WorkspaceID("notes-probe"), workspaceName: "Redesign the website",
                  hasLoaded: true, couldNotLoad: false, couldNotSave: false, hasChanges: false,
                  onRetryLoad: {}, onRetrySave: {})
    }
}
#endif
