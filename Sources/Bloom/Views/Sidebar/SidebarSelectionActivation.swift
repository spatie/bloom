import AppKit
import QuartzCore
import SwiftUI
import BloomCore

/// Gives the List's native selection one display frame before the centre pane starts loading.
/// Only a pending selection owns a display link; rapid choices replace it and detaching cancels it.
struct SidebarSelectionActivation: NSViewRepresentable {
    var selection: SidebarSelection?
    var active: SidebarSelection
    var onActivate: (SidebarSelection, SidebarSelection) -> Void

    func makeNSView(context: Context) -> SidebarActivationView { SidebarActivationView() }

    func updateNSView(_ view: SidebarActivationView, context: Context) {
        view.update(selection: selection, active: active, activate: onActivate)
    }

    static func dismantleNSView(_ view: SidebarActivationView, coordinator: ()) {
        view.cancel()
    }
}

@MainActor
final class SidebarActivationView: NSView {
    private var selection: SidebarSelection?
    private var active: SidebarSelection = .home
    private var activate: ((SidebarSelection, SidebarSelection) -> Void)?
    private var frames: CADisplayLink?
    private var hasPresentedSelection = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(
        selection: SidebarSelection?, active: SidebarSelection,
        activate: @escaping (SidebarSelection, SidebarSelection) -> Void
    ) {
        self.activate = activate
        guard self.selection != selection || self.active != active else { return }
        cancelFrames()
        self.selection = selection
        self.active = active
        schedule()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelFrames() } else { schedule() }
    }

    private func schedule() {
        guard frames == nil, window != nil, let selection, selection != active else { return }
        hasPresentedSelection = false
        let link = displayLink(target: self, selector: #selector(nextFrame))
        frames = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func nextFrame() {
        // The first callback leaves the frame entirely to the highlight. Loading starts on the
        // following callback, at the display's actual cadence rather than after an arbitrary delay.
        guard hasPresentedSelection else {
            hasPresentedSelection = true
            return
        }
        cancelFrames()
        guard let selection, let activate else { return }
        activate(selection, active)
    }

    private func cancelFrames() {
        frames?.invalidate()
        frames = nil
        hasPresentedSelection = false
    }

    func cancel() {
        cancelFrames()
        selection = nil
        activate = nil
    }
}
