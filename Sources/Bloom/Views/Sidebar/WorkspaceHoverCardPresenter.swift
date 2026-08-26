import AppKit
import SwiftUI
import BloomCore

/// Opens and closes the card that stands beside a hovered workspace row, and under a hovered pull
/// request band.
///
/// **A panel of its own rather than a `.popover` or an overlay, and each of the two it is not was
/// ruled out for a different reason.** An overlay cannot leave the sidebar: the column is an
/// `NSSplitView` subview and it clips, so a card drawn inside it is a card 260 points wide, which
/// is the width the row already had. A `.popover` does escape, and it is transient: it closes on
/// the next click anywhere outside it, and the click that closes it is the click that was meant
/// to select the row underneath. A hover affordance that eats the first click on the thing it is
/// hovering is worse than no hover affordance.
///
/// So the card is a borderless, non-activating panel that **ignores the mouse entirely**. It
/// cannot take a click, cannot take the keyboard, and cannot come between the pointer and the
/// row. That is also the whole of the answer to whether the card carries an action: it cannot,
/// and it should not, because a button on it would have to be reached across a gap by a pointer
/// whose leaving the row is the signal to close. The row's own hover controls are what actions
/// live on, a few points away and already under the pointer.
///
/// It is added as a CHILD window of the main window, which is what makes it move with the window,
/// hide with it and die with it, none of which a free-floating panel does.
///
/// Everything it closes on is listed in `watchForDismissal()`. The delay before it opens is
/// `Motion.hoverCardDelay`, shared with the composer's own chip card so the window has one answer
/// to "the pointer is resting on this rather than crossing it".
///
/// It serves two surfaces now, which is why the key below is a `Source` rather than a workspace.
/// The pull request band in the title bar opens the same card about the same workspace, and with
/// a workspace id alone, crossing from that workspace's sidebar row to its band would have been
/// read as the pointer never having moved.
@MainActor
final class WorkspaceHoverCardPresenter {
    static let shared = WorkspaceHoverCardPresenter()

    /// What is being hovered, told apart by the surface as well as by the workspace.
    enum Source: Hashable {
        case workspaceRow(WorkspaceID)
        /// The pull request band at the trailing end of the title bar. See `TitleBarStrip`.
        case pullRequestBand(WorkspaceID)
    }

    /// The thing the pointer is on, as far as this knows. Cleared by every dismissal, which is
    /// what makes a dismissal STICK: the pointer has to leave and arrive again, or arrive on
    /// something else, before anything opens. Without that a card closed by a scroll reopened
    /// under a stationary pointer the moment the scroll ended.
    private var hovered: Source?
    /// The wait between the pointer arriving and the card opening.
    private var pending: Task<Void, Never>?
    private var panel: NSPanel?
    private var hosting: NSHostingView<WorkspaceHoverCardView>?
    /// The observers and the event monitor, held for as long as this is: a singleton that lives
    /// for the life of the app never takes them down, and holding them is what says that on
    /// purpose rather than by omission.
    private var observers: [any NSObjectProtocol] = []
    private var monitor: Any?

    private init() {
        watchForDismissal()
    }

    // MARK: - The pointer

    /// The pointer has arrived on something that has a card.
    ///
    /// The card and the anchor are closures rather than values because both are read at the end of
    /// the delay rather than at the start of it: a workspace whose agent finishes mid-wait should
    /// open the card it has then, and a row the list has scrolled under the pointer should be
    /// measured where it ended up.
    ///
    /// The wait is `Motion.hoverCardDelay` for both surfaces and that is the point of it being
    /// there rather than here: it is the window's one answer to whether a pointer is resting on
    /// something or crossing it, and it is also the whole of what stops the band's card opening
    /// on a pointer travelling across the band to the Create pull request button.
    func pointerEntered(
        _ source: Source,
        card: @escaping @MainActor () -> WorkspaceHoverCard?,
        anchor: @escaping @MainActor () -> CGRect?,
        side: HoverCardPlacement.Side = .trailing
    ) {
        guard hovered != source else { return }
        hovered = source
        pending?.cancel()
        // Whatever is up belongs to something else, and crossing from one row to the next should
        // not leave the old card standing while the new one waits out its delay.
        hide()

        pending = Task { [weak self] in
            try? await Task.sleep(for: Motion.hoverCardDelay)
            guard !Task.isCancelled, let self, self.hovered == source else { return }
            guard let card = card(), let anchor = anchor() else { return }
            self.show(card, at: anchor, side: side)
        }
    }

    /// The pointer has left. Ignored when the card has since moved elsewhere, because SwiftUI
    /// delivers the arrival on the new row before the departure from the old one.
    func pointerExited(_ source: Source) {
        guard hovered == source else { return }
        dismiss()
    }

    /// Closes the card and stops anything from opening until the pointer moves again.
    func dismiss() {
        hovered = nil
        pending?.cancel()
        pending = nil
        hide()
    }

    // MARK: - The panel

    private func show(_ card: WorkspaceHoverCard, at anchor: CGRect, side: HoverCardPlacement.Side) {
        // No card over a window that is not the one being worked in. This is the same fact
        // `didResignKeyNotification` closes on, asked before opening rather than after: a window
        // can lose key during the wait.
        guard let parent = NSApp.keyWindow, parent.isVisible else { return }
        guard let screen = parent.screen ?? NSScreen.main else { return }

        let panel = panel ?? makePanel()
        self.panel = panel

        let view = WorkspaceHoverCardView(card: card)
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            panel.contentView = hosting
            self.hosting = hosting
        }

        // The card sizes itself from its content in BOTH axes, so both are asked for rather than
        // chosen: a long branch draws a wider card than a short one, and a three line workspace
        // name draws a taller card than a one line one. A panel given either number by hand would
        // clip the card or float it in dead space.
        //
        // The width still goes through `HoverCardWidth.fits` rather than being taken as it comes.
        // The card clamps itself to the same bounds, so on a laid out hosting view the two agree;
        // what this catches is the hosting view answering with a fraction, or with a zero because
        // it has not laid out yet, and a zero here is a panel with a shadow and nothing in it.
        guard let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let size = CGSize(
            width: HoverCardWidth.fits(content: fitting.width),
            height: fitting.height
        )

        panel.setFrame(
            HoverCardPlacement.frame(
                anchor: anchor, size: size, visible: screen.visibleFrame, side: side
            ),
            display: false
        )

        guard panel.parent !== parent else {
            panel.orderFront(nil)
            return
        }
        panel.parent?.removeChildWindow(panel)
        // `.above` rather than `orderFront`, so the panel is ordered relative to the window it
        // belongs to instead of to the whole screen. A card that outranked a modal sheet or
        // another application's window would be a card floating over somebody else's work.
        parent.addChildWindow(panel, ordered: .above)
        fadeIn(panel)
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 1, height: 1)),
            // `.nonactivatingPanel` on top of borderless, because a panel that activated the app
            // would put a card between the user and whatever they had brought to the front.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // The whole reason this is a panel and not a popover. Nothing here can be clicked, so
        // nothing here can be in the way of clicking the row it describes.
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // AppKit's, drawn around the alpha the card paints, which is why the card carries no
        // shadow of its own. A SwiftUI shadow inside a transparent window is clipped by the
        // window's own bounds and comes out as a hard edge on two sides.
        panel.hasShadow = true
        panel.animationBehavior = .none
        // Never in the window cycle and never on a Space of its own: it is furniture belonging to
        // the window it hangs off, and Cmd+` should not be able to land on it.
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }

    /// A short fade rather than an appearance.
    ///
    /// The card is 320 points of material arriving over a transcript somebody is reading, and at
    /// full alpha in one frame it reads as a window opening rather than as a hint. Shorter than
    /// `Motion.pane`, because it follows a deliberate 350ms rest and anything slower than the
    /// hover it answers reads as lag. Skipped entirely for Reduce Motion, which is what that
    /// setting asks for.
    private func fadeIn(_ panel: NSPanel) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 1
            return
        }
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    // MARK: - Everything that closes it

    /// The card is a statement about a row under the pointer, so anything that makes that
    /// statement stale or makes the card the wrong thing to be looking at closes it.
    ///
    /// Each of these is a case the card would otherwise survive:
    ///
    /// - **A live scroll.** The rows move and the card would go on describing the one that used to
    ///   be there. It also covers a scroll that has not started moving yet, through the wheel
    ///   events below, because `willStartLiveScroll` arrives a frame late.
    /// - **A mouse button going down anywhere.** This is the row being clicked, a row being picked
    ///   up to reorder the pane, and a right click opening the row's own context menu, and all
    ///   three want the card gone before anything else happens. It is a monitor rather than three
    ///   separate observations because a drag has no notification of its own.
    /// - **A menu opening**, which is the same context menu arriving by another route, plus every
    ///   menu bar menu.
    /// - **A sheet arriving**, since a card floating over a modal sheet belongs to a window the
    ///   user can no longer reach.
    /// - **The window losing key, and the app losing active.** A card is a hover state, and a
    ///   hover state that outlives the pointer's window is a card left on screen.
    private func watchForDismissal() {
        let centre = NotificationCenter.default
        for name in [
            NSScrollView.willStartLiveScrollNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willBeginSheetNotification,
            NSWindow.willMiniaturizeNotification,
            NSWindow.willCloseNotification,
            NSMenu.didBeginTrackingNotification,
            NSApplication.didResignActiveNotification,
        ] {
            let observer = centre.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { WorkspaceHoverCardPresenter.shared.dismiss() }
            }
            observers.append(observer)
        }

        // Local, not global: this only has to know about events going to Bloom, and a global
        // monitor is a request for the accessibility permission that Bloom has no other reason to
        // ask for. The event is returned untouched, so nothing here changes what a click does.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { event in
            MainActor.assumeIsolated { WorkspaceHoverCardPresenter.shared.dismiss() }
            return event
        }
    }
}

// MARK: - Where the anchor is

/// A handle on the `NSView` behind whatever the card is about, so the presenter can ask where it
/// is at the moment the card opens. A sidebar row, or the pull request band in the title bar.
///
/// The band is the reason this is not called a row any more, and it is also the case that proves
/// the paragraph below. A title bar accessory's SwiftUI `.global` space is a whole title bar out
/// from the window's, which is exactly the error the two AppKit conversions do not make.
///
/// A view rather than a `GeometryReader`, because what is needed is a rectangle in SCREEN
/// coordinates and SwiftUI has no coordinate space that reaches one: `.global` is the hosting
/// view's, which under a unified toolbar is neither the window's nor the screen's, and a card
/// placed from it lands a title bar's height out. `NSView.convert` and
/// `NSWindow.convertToScreen` are the two conversions that are exact, and this is what makes them
/// reachable.
///
/// Asked on demand rather than reported on every layout pass. A running agent rewrites its diff
/// stat every six seconds and the pane relays out each time; a probe that pushed a rectangle into
/// SwiftUI state on each of those would invalidate every row in the sidebar to answer a question
/// nobody had asked yet.
@MainActor
final class HoverCardAnchor {
    fileprivate weak var view: NSView?

    /// The anchor's rectangle on screen, or nil while it is not in a window, which is every row
    /// between being made and being laid out.
    var screenFrame: CGRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

/// Attaches a `HoverCardAnchor` to whatever it is put behind. Draws nothing.
struct HoverCardAnchorReader: NSViewRepresentable {
    var anchor: HoverCardAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Reattached on every update because a `List` recycles its rows: the same SwiftUI row can
        // be handed a different `NSView`, and an anchor still pointing at the old one measures a
        // rectangle that is no longer on screen.
        anchor.view = nsView
    }
}
