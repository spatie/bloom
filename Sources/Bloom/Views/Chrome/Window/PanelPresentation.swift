import AppKit

extension NSSavePanel {
    /// Presents the panel and answers what the user chose, without stopping the run loop.
    ///
    /// `runModal()` is not "this window is busy", it is "this process is busy": it runs a modal run
    /// loop, and every other workspace's transcript stops streaming for as long as the panel is
    /// open. In an app whose whole point is several agents working at once, a file picker that
    /// freezes the other ones is a bug rather than a rough edge.
    ///
    /// A sheet on the key window when there is one, because a picker raised from a control belongs
    /// to the window that control is in. `begin` otherwise, which presents the same panel with no
    /// modal run loop behind it, so a picker raised while no window is key still leaves the rest of
    /// the app running.
    @MainActor
    func present() async -> NSApplication.ModalResponse {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await beginSheetModal(for: window)
        }
        return await withCheckedContinuation { continuation in
            begin { continuation.resume(returning: $0) }
        }
    }
}
