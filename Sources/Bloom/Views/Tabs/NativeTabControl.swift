import AppKit
import BloomCore

/// Native segmented drawing and keyboard selection, with document-tab gestures around it.
final class NativeTabControl: NSSegmentedControl, NSDraggingSource {
    weak var owner: NativeTabStripView?
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { owner?.hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { owner?.hover(at: nil) }

    override func mouseDown(with event: NSEvent) {
        guard let owner, let index = owner.index(at: convert(event.locationInWindow, from: nil)) else { return }
        let tab = owner.tabs[index]
        if event.clickCount == 2, tab.canRename {
            owner.requestRename(tab.id)
            return
        }
        window?.makeFirstResponder(self)
        selectedSegment = index
        sendAction(action, to: target)

        // The control normally tracks the mouse internally. Waiting for the threshold here lets
        // a tab become an AppKit drag while a plain press still selects the native segment.
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return }
            let distance = hypot(next.locationInWindow.x - event.locationInWindow.x,
                                 next.locationInWindow.y - event.locationInWindow.y)
            guard distance >= 4 else { continue }
            owner.hover(at: nil)
            owner.onDragBegin(tab.id.id)
            let item = NSDraggingItem(pasteboardWriter: tab.id.id as NSString)
            let rect = owner.segmentRect(index)
            let image = NSImage(size: rect.size, flipped: false) { bounds in
                NSColor.controlBackgroundColor.setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
                (tab.title as NSString).draw(in: bounds.insetBy(dx: 12, dy: 4), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
                ])
                return true
            }
            item.setDraggingFrame(rect, contents: image)
            beginDraggingSession(with: [item], event: next, source: self)
            return
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, let owner,
              let index = owner.index(at: convert(event.locationInWindow, from: nil)) else {
            super.otherMouseDown(with: event)
            return
        }
        owner.tabs[index].close()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner, let index = owner.index(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return menu(forTab: owner.tabs[index].id)
    }

    func menu(forTab id: PaneContent) -> NSMenu? {
        guard let owner, let tab = owner.tabs.first(where: { $0.id == id }) else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let target = NativeTabMenuAction(action)
            let item = NSMenuItem(title: title, action: #selector(NativeTabMenuAction.invoke), keyEquivalent: "")
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }
        if tab.canRename { add("Rename Tab…") { [weak owner] in owner?.requestRename(tab.id) } }
        add(tab.closeTitle, tab.close)
        if tab.splitRight != nil || tab.splitDown != nil { menu.addItem(.separator()) }
        if let split = tab.splitRight { add("Split Right", split) }
        if let split = tab.splitDown { add("Split Down", split) }
        return menu
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        owner?.onDragEnd(!operation.isEmpty)
    }

    private func accepts(_ sender: NSDraggingInfo) -> String? {
        guard let id = sender.draggingPasteboard.string(forType: .string),
              owner?.tabs.contains(where: { $0.id.id == id }) == true else { return nil }
        return id
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) != nil else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        owner?.onDragMove(point.x)
        scrollToVisible(CGRect(x: point.x - 24, y: 0, width: 48, height: bounds.height))
        return .move
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender) != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let id = accepts(sender) else { return false }
        owner?.onDrop(id, convert(sender.draggingLocation, from: nil).x)
        return true
    }
}

private final class NativeTabMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}
