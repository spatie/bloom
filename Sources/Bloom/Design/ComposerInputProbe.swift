import AppKit
import BloomCore
import SwiftUI

#if DEBUG
/// Exercises the production glass container, text editor, drop handlers, and attachment
/// insertion in an unshown window. No mouse events, user pasteboard, or app database are used.
@MainActor
enum ComposerInputProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--composer-input-probe") }

    static func runAndExit() -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { await run() }
        RunLoop.main.run()
        exit(1)
    }

    @MainActor
    @Observable
    final class Draft {
        var text = ""
        var caret = 0
        var height = ComposerTextEditor.lineHeight
        var targeted = false
        var failures: [String] = []
        var attached: [String] = []
        let handle = ComposerEditorHandle()
        let root: String

        init(root: String) { self.root = root }

        func receive(_ sources: [AttachmentSource], at range: NSRange) -> Bool {
            do {
                let paths = try sources.map { try AttachmentFiles.attach($0, workspace: root).path }
                attached += paths
                return handle.insert(paths, replacing: range, into: text)
            } catch {
                failures.append(error.localizedDescription)
                return false
            }
        }
    }

    private struct Fixture: View {
        @Bindable var draft: Draft

        var body: some View {
            VStack(spacing: 8) {
                ComposerEditor(
                    text: $draft.text, caret: $draft.caret, isFocused: .constant(false),
                    height: draft.height, onContentHeightChange: { draft.height = $0 },
                    onKey: { _ in false }, onAttach: { draft.receive($0, at: $1) },
                    onAttachmentFailure: { draft.failures.append($0) },
                    attachmentRoot: draft.root, handle: draft.handle
                )
                HStack {
                    Button("Model") {}
                    Spacer()
                    Button("Send") {}
                }
            }
            .composerBox(isFocused: .constant(false), isFloating: true)
            .composerDropDestination(
                isTargeted: $draft.targeted,
                onReceive: { draft.receive($0, at: NSRange(location: draft.text.utf16.count, length: 0)) },
                onFailure: { draft.failures.append($0) }
            )
            .padding(16)
        }
    }

    private static func run() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bloom-input-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var failures: [String] = []
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let draft = Draft(root: directory.appending(path: "workspace").path)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            let host = NSHostingView(rootView: Fixture(draft: draft))
            window.contentView = host
            await settle(window)
            guard let text: ComposerTextView = find(in: host),
                  let surface: ComposerDropSurface = find(in: host),
                  let scroll = text.enclosingScrollView else {
                throw CocoaError(.coderValueNotFound)
            }
            var ancestor: NSView? = text
            while ancestor != nil, ancestor !== surface { ancestor = ancestor?.superview }
            check(ancestor === surface, "drop surface is not an ancestor of the native editor")

            let line = NSLayoutManager().defaultLineHeight(for: text.font!)
            for count in [1, 2, 10, 25, 1] {
                draft.text = Array(repeating: "Line", count: count).joined(separator: "\n")
                await settle(window)
                check(abs(scroll.contentSize.height - ceil(line * CGFloat(min(count, 10)))) <= 1,
                      "editor did not size to \(min(count, 10)) lines for a \(count)-line draft")
                if count > 10 {
                    check(text.frame.height > scroll.contentSize.height, "long draft cannot scroll internally")
                }
            }
            draft.text = "Line\n"
            await settle(window)
            check(abs(scroll.contentSize.height - ceil(line * 2)) <= 1, "trailing newline did not grow the editor")

            let file = directory.appending(path: "Finder file.txt")
            try Data("finder attachment".utf8).write(to: file)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let drag = InputDrag(board: board, window: window)
            board.writeObjects([file as NSURL])
            check(surface.draggingEntered(drag) == .copy, "outer surface rejected Finder file")
            check(surface.prepareForDragOperation(drag), "outer surface refused Finder drop at release")
            check(surface.performDragOperation(drag), "outer surface failed to insert Finder file")
            await settle(window)
            check(draft.text.contains("Finder file.txt"), "Finder drop was not written into the draft")

            draft.text = "Drop here"
            await settle(window)
            drag.draggingLocation = text.convert(NSPoint(x: 8, y: 8), to: nil)
            check(text.draggingEntered(drag) == .copy, "text editor rejected Finder file")
            check(text.prepareForDragOperation(drag), "text editor refused Finder drop at release")
            check(text.performDragOperation(drag), "text editor failed to attach Finder file")

            let image = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            let png = image.representation(using: .png, properties: [:])!
            board.clearContents()
            board.setData(png, forType: .png)
            check(surface.draggingEntered(drag) == .copy, "outer surface rejected screenshot bytes")
            check(surface.performDragOperation(drag), "outer surface failed to attach screenshot bytes")
            await settle(window)
            check(text.draggingEntered(drag) == .copy, "text editor rejected screenshot bytes")
            check(text.performDragOperation(drag), "text editor failed to attach screenshot bytes")
            await settle(window)
            check(draft.attached.count == 4, "drops were lost or delivered twice")
            check(draft.attached.allSatisfy {
                FileManager.default.fileExists(atPath: (draft.root as NSString).appendingPathComponent($0))
            }, "an inserted attachment has no file in the workspace")

            let writer = InputPromiseWriter(data: png)
            let promise = NSFilePromiseProvider(fileType: "public.png", delegate: writer)
            board.clearContents()
            board.writeObjects([promise])
            check(AttachmentDrop.canRead(board), "CleanShot-style file promise was not recognised")
            // AppKit requires a live window-server drag to request the promised bytes. Check
            // its advertised types above, then the delivered file's copy and lifetime here.
            let promisedDirectory: URL
            do {
                let storage = try PromisedAttachmentStorage()
                promisedDirectory = storage.directory
                let promised = storage.directory.appending(path: "Promised screenshot.png")
                try png.write(to: promised)
                check(draft.receive(
                    [.promisedFile(promised, storage)], at: NSRange(location: draft.text.utf16.count, length: 0)
                ), "delivered file promise could not be inserted")
            }
            check(draft.attached.count == 5, "delivered screenshot did not reach the draft")
            check(!FileManager.default.fileExists(atPath: promisedDirectory.path), "temporary promise files leaked")
            withExtendedLifetime((promise, writer)) {}

            board.clearContents()
            board.setString("ordinary text", forType: .string)
            check(surface.draggingEntered(drag).isEmpty, "outer surface intercepted a plain text drag")
            check(!window.isVisible && !window.isKeyWindow, "probe displayed its window")
            failures += draft.failures
        } catch {
            failures.append(error.localizedDescription)
        }
        let result: JSONValue = .object([
            "checks": .integer(checks), "passed": .bool(failures.isEmpty), "failures": .strings(failures),
            "filePromiseTransfer": .string("Requires a live drag; advertisement, receipt and cleanup checked separately"),
        ])
        ProbeHarness(subject: "composer-input").write(result)
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func settle(_ window: NSWindow) async {
        for _ in 0..<3 {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func find<T: NSView>(in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(in: $0) as T? }.first
    }
}

@MainActor
private final class InputDrag: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(board: NSPasteboard, window: NSWindow) {
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

@MainActor
private final class InputPromiseWriter: NSObject, @MainActor NSFilePromiseProviderDelegate {
    let data: Data
    init(data: Data) { self.data = data }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        "Promised screenshot.png"
    }

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        do {
            try data.write(to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { .main }
}
#endif
