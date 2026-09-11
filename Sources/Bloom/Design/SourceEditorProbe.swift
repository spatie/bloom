import AppKit
import BloomCore
import SwiftUI

#if DEBUG
/// Exercises the real editor in an unshown window, without input events or the user's database.
@MainActor
enum SourceEditorProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--source-editor-probe") }

    static func runAndExit() -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { await run() }
        RunLoop.main.run()
        exit(1)
    }

    @MainActor
    @Observable
    final class Draft {
        var text = "import Foundation\n\nfunc greeting(name: String) -> String {\n    return \"Hello, \\(name)\"\n}\n"
        var editable = true
        var identity = UUID()
        let state = SourceEditorState()
    }

    private struct Fixture: View {
        @Bindable var draft: Draft
        let model: WorkspaceModel
        var scheme: ColorScheme
        var body: some View {
            VStack(spacing: 0) {
                SourceTools(model: model, path: "Greeting.swift", state: draft.state)
                Hairline()
                SourceEditor(text: $draft.text, language: .swift, colorScheme: scheme,
                             isEditable: draft.editable, editorState: draft.state)
                    .id(draft.identity)
            }.background(Palette.surface)
        }
    }

    private static func run() async {
        let root = FileManager.default.temporaryDirectory.appending(path: "bloom-editor-probe-\(UUID())")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var failures: [String] = []
        var checks = 0
        func check(_ passed: Bool, _ reason: String) {
            checks += 1
            if !passed { failures.append(reason) }
        }
        let app = AppModel()
        let model = WorkspaceModel(workspace: Workspace(repoID: RepoID("editor-probe"), name: "editor-probe",
            branch: "editor-probe", path: root.path, baseBranch: "main"), app: app)
        let draft = Draft()
        let controller = NSHostingController(rootView: Fixture(draft: draft, model: model, scheme: .light))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 390),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        await settle(window)
        guard let text = draft.state.textView else { print("FAIL: native editor missing"); exit(1) }
        check(text.usesFindBar, "find bar unavailable")
        check(text.enclosingScrollView?.verticalRulerView != nil, "line numbers missing")
        let original = draft.text
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.insertTab(nil)
        await settle(window)
        check(draft.text.hasPrefix("    import"), "Tab did not indent")
        text.undoManager?.undo()
        await settle(window)
        check(draft.text == original, "native undo did not restore the buffer")
        draft.editable = false
        await settle(window)
        check(!text.isEditable && text.usesFindBar, "read-only files lost find support")
        draft.state.go(to: CodeLocation(path: "Greeting.swift", line: 4, column: 5))
        await settle(window)
        let expected = CodeLocation.offset(in: draft.text, line: 4, column: 5)
        check(text.selectedRange().location == expected, "line navigation missed its target")
        draft.identity = UUID()
        await settle(window)
        check(draft.state.textView?.selectedRange().location == expected, "recreating the view lost the caret")
        check(draft.state.textView?.string == original, "recreating the view changed the buffer")

        for scheme: ColorScheme in [.light, .dark] {
            window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            controller.rootView = Fixture(draft: draft, model: model, scheme: scheme)
            for width: CGFloat in [760, 420] {
                window.setContentSize(NSSize(width: width, height: 390))
                await settle(window)
                let host = controller.view
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let name = "editor-\(scheme == .light ? "light" : "dark")-\(Int(width)).png"
                    let target = URL(fileURLWithPath: "/tmp").appending(path: name)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: target)
                    print(target.path)
                }
                check(draft.state.textView?.selectedRange().location == expected, "appearance or size change lost the caret")
            }
        }
        await checkHorizontalScrolling(draft: draft, window: window, check: check)
        draft.state.wraps = true
        await settle(window)
        check(draft.state.textView?.textContainer?.widthTracksTextView == true, "wrap toggle did not update TextKit")
        do {
            let path = root.appending(path: "conflict.swift").path
            try "baseline".write(toFile: path, atomically: true, encoding: .utf8)
            let session = FileEditSession.shared
            await session.load(path: path)
            session.binding(for: path).wrappedValue = "my draft"
            try "agent version".write(toFile: path, atomically: true, encoding: .utf8)
            await session.refresh(path: path)
            check(session.draft(for: path)?.text == "my draft", "refresh overwrote the draft")
            check(session.diskVersions[path]?.text == "agent version", "comparison lost the disk version")
            await session.save(path: path)
            check(try String(contentsOfFile: path, encoding: .utf8) == "agent version", "save overwrote an unseen disk version")
            await session.keepDraftOverDisk(path: path)
            check(try String(contentsOfFile: path, encoding: .utf8) == "my draft", "explicit conflict resolution failed")
            try "new clean version".write(toFile: path, atomically: true, encoding: .utf8)
            await session.refresh(path: path)
            check(session.draft(for: path)?.text == "new clean version", "clean buffer did not refresh")
            session.discard(path: path)
        } catch { failures.append(error.localizedDescription) }
        if CommandLine.arguments.contains("--language-server") {
            do {
                let sources = root.appending(path: "Sources/Demo")
                try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
                let manifest = "// swift-tools-version: 6.2\nimport PackageDescription\nlet package = Package(name: \"Demo\", targets: [.target(name: \"Demo\")])\n"
                try manifest.write(to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
                let definition = "public func greeting() -> String { \"Hello\" }\n"
                try definition.write(to: sources.appending(path: "Greeting.swift"), atomically: true, encoding: .utf8)
                let source = "func example() { _ = greeting() }\n"
                let caller = sources.appending(path: "Caller.swift")
                try source.write(to: caller, atomically: true, encoding: .utf8)
                let offset = (source as NSString).range(of: "greeting").location
                let server = SourceLanguageServer()
                let locations = try await server.definition(root: root.path, path: caller.path,
                    text: source, offset: offset, language: .swift)
                await server.close()
                check(locations.contains { $0.path.hasSuffix("Greeting.swift") && $0.line == 1 },
                      "SourceKit did not resolve a definition in another file: \(locations)")
            } catch { failures.append("Language server: " + error.localizedDescription) }
        }
        print("Source editor probe: \(checks) checks, \(failures.count) failures")
        for failure in failures { print("FAIL: \(failure)") }
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func checkHorizontalScrolling(
        draft: Draft, window: NSWindow, check: (Bool, String) -> Void
    ) async {
        draft.text = String(repeating: "longLine ", count: 400) + "endOfLine"
        await settle(window)
        guard let view = draft.state.textView, let scroll = view.enclosingScrollView,
              let ruler = scroll.verticalRulerView else {
            check(false, "long-line preview missing")
            return
        }
        ruler.viewWillDraw()
        let inset = view.textContainerInset.width
        let initial = view.convert(view.textContainerOrigin, to: scroll).x
        scroll.contentView.scroll(to: NSPoint(x: 500, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        ruler.viewWillDraw()
        await settle(window)
        check(scroll.contentView.bounds.minX >= 499, "long-line preview did not scroll horizontally")
        check(abs(view.textContainerInset.width - inset) < 1, "scrolling changed the gutter inset")
        let shifted = view.convert(view.textContainerOrigin, to: scroll).x
        check(initial - shifted >= 499, "horizontal scrolling did not reveal later text")
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private static func settle(_ window: NSWindow) async {
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(250))
        window.contentView?.layoutSubtreeIfNeeded()
    }
}
#endif
