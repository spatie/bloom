import AppKit
import BloomCore
import SwiftUI

/// A tab being carried by the pointer: along the strip to a new slot, or down out of it onto a pane.
///
/// **Why this is not a system drag any more.** The strip used to hang `.draggable` off every tab,
/// so what followed the pointer was AppKit's drag image rather than the tab, and the strip learned
/// where the pointer was from a drop session. Safari carries the tab itself and the neighbours move
/// out of its way, and nothing about a system drag lets a view draw its own source under the
/// pointer: the image is a snapshot taken when the drag starts. So a tab is carried by a
/// `DragGesture` now, and a tab taken out of the strip is hit tested against the panes by the column
/// rather than being offered to an `NSDraggingDestination`. That also retires the fault
/// `CenterPaneView` used to document, where a `WKWebView` registered its own dragged types over the
/// pane's destination and a tab could never be dropped on a browser pane.
///
/// One object owned by the column and handed to the strip, because two regions of the window draw
/// the same drag: the strip slides its tabs and the column washes the pane a tab would land in.
///
/// `@Observable` rather than `@State` in either view, and the reason is how often it is written.
/// The pointer moves every frame, and a `@State` in the column would rebuild the column, and with
/// it every transcript and terminal under it, sixty times a second. Observation tracks each property
/// separately, so `travel` invalidates only the one tab reading it, `target` only the neighbours,
/// `pointer` only the ghost and `landing` only the wash. Every setter below checks for a change
/// first, because assigning an equal value is still a mutation as far as Observation is concerned.
@MainActor
@Observable
final class TabCarry {
    /// What was picked up, and the strip as it was at that moment.
    struct Lift: Equatable {
        var content: PaneContent
        /// The strip in stored order when the drag began. The drag is cancelled if the strip stops
        /// being this list, because `geometry` describes this list and no other.
        var run: [PaneContent]
        var geometry: TabStripDrag
        /// What the ghost says once the tab is out over the panes.
        var title: String
        var symbol: String
    }

    private(set) var lift: Lift?
    /// How far the pointer has travelled sideways since the tab was picked up.
    private(set) var travel: Double = 0
    /// The slot the carried tab would land in, and nil while it is out of the strip.
    private(set) var target: Int?
    private(set) var isInStrip = true
    /// Where the pointer is, in `CenterColumnView.space`.
    private(set) var pointer: CGPoint = .zero
    /// The part of a pane the tab would land in, in `CenterColumnView.space`, and nil for anywhere
    /// that would not take it.
    private(set) var landing: PaneLanding?

    /// Escape pressed mid drag. The gesture carries on delivering movement until the button comes
    /// up, and every one of those has to be ignored or the tab would be picked straight up again.
    @ObservationIgnored private(set) var isCancelled = false
    /// Whether the click that ends a drag should be kept from selecting the tab.
    ///
    /// A tab's select is a `TapGesture` recognised alongside the drag, and a press that moved and
    /// came back up can still read as a tap to it. Picking a tab up is not asking to open it: the
    /// panes below are the selected tab's, and switching them away under a drag heading for one of
    /// them would move the target. Set when a drag begins and cleared a turn of the run loop after
    /// it ends, which is after both recognisers have seen the same mouse up.
    @ObservationIgnored private(set) var swallowsSelect = false
    @ObservationIgnored private var escapeMonitor: Any?

    /// Picks a tab up.
    func begin(_ lift: Lift, cancelAnimation: Animation?) {
        self.lift = lift
        travel = 0
        target = lift.geometry.dragged
        isInStrip = true
        landing = nil
        swallowsSelect = true
        watchEscape(animation: cancelAnimation)
    }

    /// The pointer has moved. Only the slot and the strip band are animated, because those are
    /// what move the OTHER tabs; the carried tab follows the pointer and an animation on it would
    /// drag it behind the hand.
    func move(
        travel: Double, pointer: CGPoint, isInStrip: Bool, landing: PaneLanding?, animation: Animation?
    ) {
        guard let lift else { return }
        if travel != self.travel { self.travel = travel }
        if pointer != self.pointer { self.pointer = pointer }
        if landing != self.landing { self.landing = landing }
        if isInStrip != self.isInStrip {
            withAnimation(animation) { self.isInStrip = isInStrip }
        }
        let target = isInStrip ? lift.geometry.target(for: travel) : nil
        if target != self.target {
            withAnimation(animation) { self.target = target }
        }
    }

    /// Puts everything down. Called inside whatever transaction the caller wants the tabs to
    /// settle in.
    func end() {
        stopWatchingEscape()
        if lift != nil { lift = nil }
        if travel != 0 { travel = 0 }
        if target != nil { target = nil }
        if !isInStrip { isInStrip = true }
        if landing != nil { landing = nil }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.swallowsSelect = false
        }
    }

    /// Returns the tab to its slot and ignores the rest of the gesture.
    func cancel(animation: Animation?) {
        guard lift != nil else { return }
        isCancelled = true
        withAnimation(animation) { end() }
    }

    /// The button has come up, so the next press starts afresh.
    func gestureEnded() {
        isCancelled = false
    }

    // MARK: - What a tab draws

    /// Whether `content` is the tab under the pointer.
    func isCarrying(_ content: PaneContent) -> Bool {
        lift?.content == content
    }

    /// How far `content` is drawn from its place in the row.
    ///
    /// The carried tab reads `travel` and the others read `target`, and that split is the point:
    /// see the type's own comment on what each property invalidates.
    func offset(of content: PaneContent) -> Double {
        guard let lift, isInStrip else { return 0 }
        if lift.content == content {
            return lift.geometry.clamped(travel)
        }
        guard let target, let index = lift.run.firstIndex(of: content) else { return 0 }
        return lift.geometry.slotOffsets(target: target)[index]
    }

    // MARK: - Escape

    /// A local monitor rather than `onKeyPress` or `onExitCommand`, because either of those needs
    /// the tab to hold keyboard focus and a tab never does: the composer or the terminal keeps it
    /// while the pointer is busy in the strip, and taking it away to cancel a drag would leave the
    /// user typing into nothing afterwards.
    ///
    /// Bare Escape only, read off the key code for the reason `WindowCloseShortcut` gives, and
    /// swallowed, because the Escape was spent on the drag and should not also dismiss a popover or
    /// interrupt an agent in the pane underneath.
    private func watchEscape(animation: Animation?) {
        stopWatchingEscape()
        // The event never crosses into the main actor closure, only the answer does, for the
        // reason `WindowCloseShortcut` gives: an `NSEvent` is not `Sendable`, and the handler is
        // already on the main thread.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == Self.escapeKeyCode, modifiers.isEmpty else { return event }
            let spent = MainActor.assumeIsolated {
                guard let self, self.lift != nil else { return false }
                self.cancel(animation: animation)
                return true
            }
            return spent ? nil : event
        }
    }

    private func stopWatchingEscape() {
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
    }

    private nonisolated static let escapeKeyCode: UInt16 = 53
}
