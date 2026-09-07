import AppKit
import SwiftUI

/// Keep the pane mounted without leaving an AppKit terminal or editor able to accept input.
/// SwiftUI's disabled environment alone does not stop a native view that is first responder.
struct ArchiveInteractionShield: NSViewRepresentable {
    func makeNSView(context: Context) -> Shield { Shield() }
    func updateNSView(_ view: Shield, context: Context) {}

    final class Shield: NSView {
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        override func keyDown(with event: NSEvent) {}
        override func mouseDown(with event: NSEvent) {}
        override func rightMouseDown(with event: NSEvent) {}
    }
}
