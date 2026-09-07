import AppKit
import BloomCore
import QuickLookUI
import SwiftUI

/// Native text attachments and SwiftUI chips share one preview route. Hit testing is done at
/// the key press, so scrolling under a stationary pointer never leaves a stale file selected.
@MainActor
protocol HoverQuickLookSource: AnyObject {
    func quickLookURL(at point: NSPoint) -> URL?
}

struct HoverQuickLook: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> HoverQuickLookAnchor { HoverQuickLookAnchor(url: url) }

    func updateNSView(_ view: HoverQuickLookAnchor, context: Context) { view.url = url }

    static func dismantleNSView(_ view: HoverQuickLookAnchor, coordinator: Void) {
        HoverQuickLookController.shared.remove(view)
    }
}

final class HoverQuickLookAnchor: NSView, HoverQuickLookSource {
    var url: URL

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        HoverQuickLookController.shared.update(self)
    }

    func quickLookURL(at point: NSPoint) -> URL? { url }
}

/// One monitor and weak sources for the whole app. An explicit hover + Space temporarily owns
/// the responder chain, otherwise a focused inspector list can take the shared Quick Look panel
/// back and display its selected file instead. Closing restores the previous keyboard focus.
@MainActor
final class HoverQuickLookController: NSResponder, @MainActor QLPreviewPanelDataSource, @MainActor QLPreviewPanelDelegate {
    static let shared = HoverQuickLookController()

    private var url: URL?
    private var monitor: Any?
    private let sources = NSHashTable<NSView>.weakObjects()
    private var intent = HoverPreviewIntent()
    private var lastPointer = NSEvent.mouseLocation
    private weak var sourceWindow: NSWindow?
    private weak var previousResponder: NSResponder?

    override var acceptsFirstResponder: Bool { true }

    func update(_ source: NSView & HoverQuickLookSource) {
        guard source.window != nil else { remove(source); return }
        sources.add(source)
        guard monitor == nil else { return }
        lastPointer = NSEvent.mouseLocation
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { Self.shared.handle(event) } ? nil : event
        }
    }

    func remove(_ source: NSView) {
        sources.remove(source)
        if sources.allObjects.isEmpty, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, window === NSApp.keyWindow,
              !(window is QLPreviewPanel) else { return false }
        let pointer = NSEvent.mouseLocation
        let moved = pointer != lastPointer
        lastPointer = pointer
        // The layout lookup is only needed for Space, not for every character typed in a chat.
        let target = event.keyCode == 49 ? target(in: window) : nil
        let opens = intent.keyPressed(
            keyCode: event.keyCode,
            hasModifiers: !event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift, .function]),
            isRepeat: event.isARepeat,
            pointerMoved: moved,
            isOverFile: target != nil,
            hasSheet: window.attachedSheet != nil
        )
        guard opens, let target else { return false }
        return show(target, in: window)
    }

    private func target(in window: NSWindow) -> URL? {
        for view in sources.allObjects where view.window === window && !view.isHiddenOrHasHiddenAncestor {
            let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard view.visibleRect.contains(point),
                  let source = view as? any HoverQuickLookSource,
                  let url = source.quickLookURL(at: point) else { continue }
            return url
        }
        return nil
    }

    @discardableResult
    func show(_ candidate: URL, in window: NSWindow? = nil) -> Bool {
        guard candidate.isFileURL, let url = QuickLookTarget.url(for: candidate.path),
              let window = window ?? NSApp.keyWindow,
              window.attachedSheet == nil,
              let panel = QLPreviewPanel.shared() else { return false }
        self.url = url
        sourceWindow = window
        previousResponder = window.firstResponder
        nextResponder = window
        guard window.makeFirstResponder(self) else { restoreFocus(); return false }
        panel.updateController()
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { sourceWindow != nil && url != nil }
    }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            if panel.dataSource === self { panel.dataSource = nil; panel.delegate = nil }
            restoreFocus()
        }
    }

    private func restoreFocus() {
        let window = sourceWindow
        let responder = previousResponder
        sourceWindow = nil
        previousResponder = nil
        url = nil
        nextResponder = nil
        if window?.firstResponder === self { window?.makeFirstResponder(responder) }
    }

    func windowWillClose(_ notification: Notification) { restoreFocus() }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL?
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown,
              event.keyCode == 49 || event.keyCode == 53,
              event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift, .function])
        else { return false }
        if !event.isARepeat { panel.orderOut(nil); restoreFocus() }
        return true
    }
}
