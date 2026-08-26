import AppKit
import BloomCore
import QuartzCore

extension Notification.Name {
    /// A divider that resizes a pane has been taken hold of, and let go.
    ///
    /// Posted by `CenterPaneDivider`, which is a SwiftUI `DragGesture` and therefore not a live
    /// resize as far as AppKit is concerned. Without it a hand pausing mid drag would reach the
    /// hold's quiet deadline and reflow the transcript under itself.
    static let bloomPaneResizeBegan = Notification.Name("bloom.paneResize.began")
    static let bloomPaneResizeEnded = Notification.Name("bloom.paneResize.ended")
}

/// What a held transcript is asked to do. `TranscriptTable.Coordinator` is the only one.
@MainActor
protocol TranscriptHoldDelegate: AnyObject {
    /// A hold has begun. What it is holding is the whole of the difference between the two.
    func holdBegan(_ held: TranscriptHoldView.Held)
    /// The pane may be drawn again. True when there was anything to show for the wait, which is
    /// what decides whether the fade is worth playing.
    func holdEnded(_ held: TranscriptHoldView.Held) -> Bool
    /// Stop being held, and lay out nothing: what was held belongs to a conversation the pane has
    /// already left. See `hold(_:)`.
    func holdCancelled()
    var reducesMotion: Bool { get }
}

/// **Holds a transcript back while its pane is not ready to show it, and fades to it when it is.**
///
/// One mechanism, one way in and one way out, asked by three triggers that differ in one thing
/// only: what there is to hold. `hold(_:)` takes that as `Held` and `ready()` ends every one of
/// them the same way.
///
/// - **A drag** halves or widens the pane under the reader's hand: `.whatIsDrawn`.
/// - **A split** halves it too, but the pane is rebuilt rather than resized (see `CenterPanesView`,
///   whose `ForEach` identity deliberately changes when a tab goes from one pane to two), so the
///   arriving pane has no pixels of its own to keep: `.nothing`.
/// - **An arrival**, which is a workspace switch, a tab switch and the pane's first conversation:
///   `.nothing`, because what is on screen belongs to the conversation being left.
///
/// ## What `.whatIsDrawn` does
///
/// **The trick is Safari's**, in the owner's words: dragging its sidebar does not redraw the page,
/// the page appears beside the new edge at the size it already had, and the reflowed one is faded
/// in once it is laid out. Here that is one line: while the hold is on, the scroll view keeps the
/// frame it had. Nothing inside it is resized, so no cell relayouts, no `NSHostingView` is built,
/// no height is remeasured and `TranscriptTable` never hears the pane moved at all. The strip of
/// pane that opens up beside it is drawn by whatever is behind this view, which is the transcript's
/// own background, so the content neither stretches nor distorts: it is exactly the pixels that
/// were there, in the place they were.
///
/// ## What `.nothing` does
///
/// It draws the pane's own background and takes no clicks. A pane is NOT torn down by a workspace
/// switch: the centre column hands the same view a different model and a different session, so
/// without this the rows on screen for the moment after the switch are the conversation being
/// left, then the tail lands at the top of the pane, then the view jumps to the live end. Three of
/// those four states are a transcript nobody asked to see.
///
/// A picture of the pane's own last frame would be better than nothing here and is not available:
/// `Snapshot` records the measurement that `cacheDisplay` misses anything whose content lives in a
/// layer, and `layer.render(in:)` misses whole view controller hierarchies. What makes the blank
/// acceptable is that it is short: nothing is measured up front any more, so a pane arrives in the
/// time it takes to read its rows and measure one screen of them.
///
/// ## The fade, and letting go
///
/// The fade is a `CATransition` on this view's layer, for the same measurement: the render server
/// crossfades what it already has against the next commit, and everything the reveal does happens
/// in that commit, so the new layout is complete before a frame of the fade is drawn.
///
/// **Every hold is armed to let go by itself.** A drag that is interrupted, a window zoomed or
/// tiled, a display change, `--window-size`, a pane taken off screen, a conversation that never
/// loads: all of them end at a deadline in `TranscriptPaneHold`, without anything having to
/// arrive. Nothing here needs an end event, which is why it is safe to hold for gestures and
/// arrivals that do not send one.
///
/// **Nothing held here can belong to another pane.** The frozen thing is this view's own scroll
/// view, in place, and everything else is drawn as nothing at all. There is no store of pictures
/// to look a pane up in and therefore no way to reach the wrong one: the guarantee is the shape of
/// the mechanism rather than a rule somebody has to keep.
final class TranscriptHoldView: NSView {
    /// What a hold is holding, which is the whole of the difference between the three triggers.
    ///
    /// The core's, under a shorter name. The deadline each kind is armed with is a decision and
    /// lives with the other decisions; this is the mechanism, and the two must not be able to
    /// disagree about what the kinds are.
    typealias Held = TranscriptPaneHold.PaneHeld

    let scroll: NSScrollView
    weak var delegate: TranscriptHoldDelegate?

    /// What this pane is holding, and nil when it is drawing itself normally.
    private(set) var held: Held?
    /// The frame the scroll view keeps while `.whatIsDrawn` is on.
    private var frozen: NSRect?
    /// Whether a divider is known to be under a hand. See `bloomPaneResizeBegan`.
    private var isUnderAHand = false
    /// The last width this view was asked to be, so a change is noticed once however AppKit and
    /// SwiftUI happen to deliver it.
    private var lastWidth: CGFloat = 0
    private var letGo: Task<Void, Never>?

    private static let fadeKey = "bloom.transcript.reveal"

    init(scroll: NSScrollView) {
        self.scroll = scroll
        super.init(frame: .zero)
        wantsLayer = true
        // A held scroll view is wider than this view for the whole of a drag that narrows the
        // pane, and without this it draws over the pane beside it.
        clipsToBounds = true
        autoresizesSubviews = false
        addSubview(scroll)

        let centre = NotificationCenter.default
        centre.addObserver(
            self, selector: #selector(handTookHold), name: .bloomPaneResizeBegan, object: nil
        )
        centre.addObserver(
            self, selector: #selector(handLetGo), name: .bloomPaneResizeEnded, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Nothing reaches a pane that is not being drawn. A wheel event during an arrival would take
    /// the standing instruction to be at the live end off a transcript nobody can see yet, and the
    /// reader would be somewhere they never scrolled to when it fades in.
    override func hitTest(_ point: NSPoint) -> NSView? {
        held == .nothing ? nil : super.hitTest(point)
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
        noteWidth(newSize.width)
    }

    override func layout() {
        super.layout()
        // Both hooks, because which of the two SwiftUI's host uses to resize a representable is
        // not something to depend on. `noteWidth` is idempotent, so being told twice costs
        // nothing and being told once is enough.
        noteWidth(bounds.width)
        scroll.frame = frozen ?? bounds
    }

    // MARK: - The one way in

    /// **This pane is about to be laid out differently. Hold what is drawn, let the work happen,
    /// and fade the result in.**
    ///
    /// Idempotent per kind: a drag that goes on changing the width re-arms the deadline rather
    /// than starting a second hold. An arrival outranks a resize, because the pixels a resize was
    /// keeping belong to a conversation this pane has just left.
    func hold(_ what: Held) {
        if held == what {
            armLetGo()
            return
        }

        if what == .nothing, frozen != nil {
            // Cancelled rather than ENDED, and laid out on the next pass rather than this one,
            // because an arrival is announced from inside `updateNSView` and a reflow reports
            // geometry, which writes SwiftUI state.
            frozen = nil
            needsLayout = true
            delegate?.holdCancelled()
        }

        held = what
        switch what {
        case .whatIsDrawn:
            // The frame the scroll view has NOW, which is the one it was laid out at.
            frozen = scroll.frame
        case .nothing:
            scroll.alphaValue = 0
        }
        TranscriptHoldCensus.held(what, underAHand: isUnderAHand, liveResize: inLiveResize)
        delegate?.holdBegan(what)
        armLetGo()
    }

    /// **The one way out.** The pane may be drawn again: reflow if the hold owes one, and fade to
    /// whatever that leaves.
    func ready() {
        letGo?.cancel()
        letGo = nil
        guard let what = held else { return }
        held = nil
        frozen = nil
        fading {
            needsLayout = true
            // The scroll view takes the pane's width here, which is what tells the table it moved.
            layoutSubtreeIfNeeded()
            scroll.alphaValue = 1
            // A reflow that finds nothing to do is a drag that ended where it started, and there
            // is nothing to crossfade. An arrival always has something: the conversation.
            let moved = delegate?.holdEnded(what) ?? false
            return what == .nothing || moved
        }
        TranscriptHoldCensus.revealed()
    }

    private func armLetGo() {
        letGo?.cancel()
        let deadline = TranscriptPaneHold.letsGo(
            of: held ?? .whatIsDrawn, underAHand: isUnderAHand || inLiveResize
        )
        letGo = Task { @MainActor [weak self] in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            self?.ready()
        }
    }

    /// Crossfades this pane from what the render server already has to whatever `change` leaves.
    ///
    /// The transition goes on BEFORE the change it covers and comes off again if the change turns
    /// out to have been nothing: an animation added and removed inside one run loop turn never
    /// reaches a frame.
    private func fading(_ change: () -> Bool) {
        let seconds = delegate?.reducesMotion == true ? 0 : Motion.revealSeconds
        if seconds > 0 {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = seconds
            layer?.add(fade, forKey: Self.fadeKey)
        }
        if !change() { layer?.removeAnimation(forKey: Self.fadeKey) }
    }

    // MARK: - What asks for a hold

    /// A width change, however it was produced: a divider under a hand, a window edge, a zoom, a
    /// tiling, a display change, the inspector collapsing, or a probe driving any of them.
    private func noteWidth(_ width: CGFloat) {
        guard width != lastWidth else { return }
        let before = lastWidth
        lastWidth = width
        // A pane that is not drawing anything has nothing to freeze, and the reflow a freeze would
        // owe is the one the arrival is about to do anyway.
        guard window != nil, held != .nothing else { return }
        guard TranscriptPaneHold.holds(from: Double(before), to: Double(width)) else { return }
        hold(.whatIsDrawn)
    }

    @objc private func handTookHold() {
        isUnderAHand = true
        if held != nil { armLetGo() }
    }

    @objc private func handLetGo() {
        isUnderAHand = false
        guard held == .whatIsDrawn else { return }
        ready()
    }

    /// The window's own edge, and any divider AppKit resizes panes for. Nothing is held here: the
    /// first width change is, so a window made taller freezes nothing.
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        TranscriptHoldCensus.liveResizeBegan()
        if held != nil { armLetGo() }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard held == .whatIsDrawn else { return }
        ready()
    }

    /// A pane put away mid drag must not come back holding a picture of the width it used to be.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        guard held == .whatIsDrawn else { return }
        ready()
    }
}
