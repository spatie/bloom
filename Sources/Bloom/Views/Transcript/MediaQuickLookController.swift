import AppKit
import BloomCore
import QuickLookUI
import SwiftUI

/// A passive image-sized anchor. Geometry is checked when Space arrives, not cached on mouse
/// entry: scrolling or recycling a transcript row under a stationary pointer changes the target.
struct MediaQuickLookHotspot: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> MediaQuickLookAnchor {
        MediaQuickLookAnchor(url: url)
    }

    func updateNSView(_ view: MediaQuickLookAnchor, context: Context) {
        view.url = url
    }

    static func dismantleNSView(_ view: MediaQuickLookAnchor, coordinator: Void) {
        MediaQuickLookController.shared.remove(view)
    }
}

final class MediaQuickLookAnchor: NSView {
    var url: URL

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            MediaQuickLookController.shared.remove(self)
        } else {
            MediaQuickLookController.shared.add(self)
        }
    }

    func isUnderPointer(in candidate: NSWindow) -> Bool {
        guard window === candidate, !isHiddenOrHasHiddenAncestor else { return false }
        return visibleRect.contains(convert(candidate.mouseLocationOutsideOfEventStream, from: nil))
    }
}

/// One event monitor for all visible images, with weak anchors so the shared Quick Look panel
/// never keeps a transcript alive. Hover does not move focus; only the explicit Space opens it.
@MainActor
final class MediaQuickLookController: NSObject, @MainActor QLPreviewPanelDataSource, @MainActor QLPreviewPanelDelegate {
    static let shared = MediaQuickLookController()

    private var url: URL?
    private var monitor: Any?
    private let anchors = NSHashTable<MediaQuickLookAnchor>.weakObjects()

    func add(_ anchor: MediaQuickLookAnchor) {
        anchors.add(anchor)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { Self.shared.handle(event) } ? nil : event
        }
    }

    func remove(_ anchor: MediaQuickLookAnchor) {
        anchors.remove(anchor)
        if anchors.allObjects.isEmpty, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard event.keyCode == 49,
              let window = event.window, window === NSApp.keyWindow else { return false }
        let anchor = anchors.allObjects.first { $0.isUnderPointer(in: window) }
        guard MediaPreviewShortcut.opens(
            keyCode: event.keyCode,
            hasModifiers: !event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift, .function]),
            isRepeat: event.isARepeat,
            isOverImage: anchor != nil,
            hasSheet: window.attachedSheet != nil
        ), let anchor else { return false }
        show(anchor.url)
        return true
    }

    func show(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path),
              let panel = QLPreviewPanel.shared() else { return }
        self.url = url
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL?
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown,
              event.keyCode == 49 || event.keyCode == 53,
              event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift, .function])
        else { return false }
        if !event.isARepeat { panel.orderOut(nil) }
        return true
    }
}
