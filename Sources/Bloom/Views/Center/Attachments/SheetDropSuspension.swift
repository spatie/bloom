import AppKit

/// Takes a view's drag types away while its window has a sheet on it, and gives them back when the
/// sheet goes.
///
/// A sheet does not stop a window's views from being offered a drag, and a composer partly under it
/// took the file for the chat behind. With its types gone the drag falls through to the ancestor
/// that routes it, `WindowFileDrop`, which sends it to the sheet's own composer. Restoring what the
/// view had rather than the composer's own list matters for the text view, whose set includes the
/// text system's defaults.
@MainActor
final class SheetDropSuspension {
    private weak var view: NSView?
    private var suspendedTypes: [NSPasteboard.PasteboardType]?
    private var observers: [any NSObjectProtocol] = []

    init(_ view: NSView) { self.view = view }

    func windowChanged(to window: NSWindow?) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.willBeginSheetNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend() }
            },
            center.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            },
        ]
        if window.attachedSheet != nil { suspend() }
    }

    private func suspend() {
        guard suspendedTypes == nil, let view else { return }
        suspendedTypes = view.registeredDraggedTypes
        view.unregisterDraggedTypes()
    }

    private func resume() {
        guard let types = suspendedTypes, let view else { return }
        suspendedTypes = nil
        view.registerForDraggedTypes(types)
    }

    isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
