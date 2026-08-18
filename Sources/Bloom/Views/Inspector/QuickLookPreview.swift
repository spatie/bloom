import SwiftUI
import AppKit
import QuickLookUI

/// Whether a path is worth handing to Quick Look at all.
///
/// There is no public API that answers "can you preview this", so the question is asked the only
/// way it can be: is there a regular, readable, non-empty file at the end of the path. That
/// already covers the cases the inspector actually produces. A deleted file is still a row in the
/// changed list, a directory is still a row in the tree, and both would open a panel that shows
/// the reader nothing they cannot see in the row itself.
enum QuickLookTarget {
    static func url(for path: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }
        guard !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: path) else {
            return nil
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int ?? 0
        guard size > 0 else { return nil }

        return URL(fileURLWithPath: path)
    }
}

/// Space bar Quick Look for a file list, the way Finder does it.
///
/// This is an AppKit view rather than `focusable()` and `onKeyPress` for two reasons, and they are
/// the same reason twice. `QLPreviewPanel` is driven from the responder chain: it walks up from the
/// first responder looking for something that accepts control of it, and hands that object the
/// panel's data source. And the space bar must only be ours while the list is the thing the
/// keyboard is pointed at, which is exactly what being the first responder means. One `NSView`
/// answers both: it takes the responder when a row is picked, so it hears the space bar and the
/// panel finds it, and it loses the responder the moment the reader clicks into the composer or a
/// terminal, so the space bar goes back to being a space.
///
/// Placed as a background of the list, so the rows above it keep every click.
struct QuickLookHost: NSViewRepresentable {
    /// The file the space bar would preview. Nil disarms it without tearing the host down.
    var url: URL?
    /// Bumped by the list every time a row is activated, which is what moves the keyboard back
    /// here after the reader has been somewhere else. Selection alone is not enough: clicking the
    /// already selected row is a legitimate way to ask for it again.
    var armToken: Int

    func makeNSView(context: Context) -> QuickLookHostView {
        QuickLookHostView()
    }

    func updateNSView(_ view: QuickLookHostView, context: Context) {
        view.update(url: url, armToken: armToken)
    }
}

final class QuickLookHostView: NSView, @MainActor QLPreviewPanelDataSource, @MainActor QLPreviewPanelDelegate {
    private var url: URL?
    private var armToken = 0

    override var acceptsFirstResponder: Bool { true }

    /// Invisible to the mouse. It is a background of the list, so every point in it is over a row,
    /// and an `NSView` added to a hosting view's hierarchy hit-tests ahead of what SwiftUI draws
    /// itself. Being first responder does not go through hit testing, so nothing here needs it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(url: URL?, armToken: Int) {
        let changed = self.url != url
        self.url = url

        if armToken != self.armToken {
            self.armToken = armToken
            window?.makeFirstResponder(self)
        }

        // A panel left open while the reader walks the list follows the selection rather than
        // going stale, which is what Finder does with the arrow keys.
        guard changed, isPanelOpen else { return }
        QLPreviewPanel.shared()?.reloadData()
    }

    override func keyDown(with event: NSEvent) {
        guard isSpace(event) else {
            super.keyDown(with: event)
            return
        }
        toggle()
    }

    /// Bare space only. Every combination with a modifier belongs to somebody else, from the
    /// system's own Command-Space down.
    private func isSpace(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        return modifiers.isEmpty && event.charactersIgnoringModifiers == " "
    }

    private var isPanelOpen: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }

    /// Space closes an open panel as well as opening one, which is the whole of the Finder
    /// gesture. With nothing previewable selected it does nothing rather than beeping: the reader
    /// pressed a key at a deleted file, and a beep tells them off for it.
    private func toggle() {
        guard let panel = QLPreviewPanel.shared() else { return }

        if isPanelOpen {
            panel.orderOut(nil)
            return
        }

        guard url != nil else { return }
        window?.makeFirstResponder(self)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - Panel control

    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    // MARK: - Contents

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL?
    }

    /// The panel forwards keys it does not use itself, and the one worth taking back is the space
    /// bar: without this it closes only on Escape, so the gesture would not be symmetric.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, isSpace(event) else { return false }
        panel.orderOut(nil)
        return true
    }
}
