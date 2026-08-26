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
    /// Stop applying anything: nothing is remeasured, nothing is reloaded, no row lands.
    func holdBegan()
    /// Lay out at the new width. True when anything actually moved.
    func holdEnded() -> Bool
    /// Stop being held, and lay out nothing: what was held belongs to a conversation the pane has
    /// already left. See `holdForArrival`.
    func holdCancelled()
    var reducesMotion: Bool { get }
}

/// Holds a transcript back while the pane it is in is not ready to show it, and fades to it when
/// it is. Twice: a pane being resized, and a pane being pointed at another conversation.
///
/// ## A resize
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
/// **The fade is a `CATransition` rather than a picture we take.** `Snapshot` records the
/// measurement: `cacheDisplay` misses anything whose content lives in a layer rather than in
/// `draw(_:)`, and `layer.render(in:)` misses whole view controller hierarchies, so a bitmap of
/// this pane is not something to build a crossfade on. A transition on this view's layer makes the
/// render server crossfade what it already has against the next commit, and the reflow happens in
/// that same commit, so the new layout is complete before a frame of the fade is drawn.
///
/// **Every hold is armed to let go by itself.** A drag that is interrupted, a window zoomed or
/// tiled, a display change, `--window-size`, and a pane taken off screen all end at
/// `TranscriptPaneHold.quiet` after the last width change, which is 200ms. Nothing here needs an
/// end event to arrive, which is why it is safe to hold for gestures that do not send one.
///
/// ## An arrival
///
/// The second thing this pane does that takes longer than a frame: see `holdForArrival`. The two
/// holds cannot both be running, because a pane that has just been pointed at another conversation
/// has nothing worth freezing, and `holdForArrival` ends a resize hold that was.
///
/// **Nothing held here can belong to another pane.** The frozen thing is this view's own scroll
/// view, in place, and an arrival is drawn as nothing at all. There is no store of pictures to
/// look a pane up in and therefore no way to reach the wrong one: the guarantee is the shape of
/// the mechanism rather than a rule somebody has to keep.
final class TranscriptHoldView: NSView {
    let scroll: NSScrollView
    weak var delegate: TranscriptHoldDelegate?

    /// The frame the scroll view keeps for as long as the transcript is held, and nil when it is
    /// following this view again.
    private var frozen: NSRect?
    /// Whether a divider is known to be under a hand. See `bloomPaneResizeBegan`.
    private var isUnderAHand = false
    /// The last width this view was asked to be, so a change is noticed once however AppKit and
    /// SwiftUI happen to deliver it.
    private var lastWidth: CGFloat = 0
    private var letGo: Task<Void, Never>?
    /// Whether this pane is waiting for the conversation it has been pointed at. See
    /// `holdForArrival`.
    private var isArriving = false
    private var reveal: Task<Void, Never>?

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
        isArriving ? nil : super.hitTest(point)
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

    // MARK: - Holding

    private func noteWidth(_ width: CGFloat) {
        guard width != lastWidth else { return }
        let before = lastWidth
        lastWidth = width
        guard window != nil, !isArriving else { return }
        guard TranscriptPaneHold.holds(from: Double(before), to: Double(width)) else { return }
        if frozen == nil {
            // The frame the scroll view has NOW, which is the one it was laid out at.
            frozen = scroll.frame
            TranscriptHoldCensus.held(underAHand: isUnderAHand, liveResize: inLiveResize)
            delegate?.holdBegan()
        }
        armLetGo()
    }

    private func armLetGo() {
        letGo?.cancel()
        let deadline = TranscriptPaneHold.letsGo(underAHand: isUnderAHand || inLiveResize)
        letGo = Task { @MainActor [weak self] in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            self?.release()
        }
    }

    /// Lets the transcript out at the width the pane is now, and crossfades to it.
    private func release() {
        letGo?.cancel()
        letGo = nil
        guard frozen != nil else { return }
        frozen = nil
        fading {
            needsLayout = true
            // The scroll view takes the pane's width here, which is what tells the table it moved.
            layoutSubtreeIfNeeded()
            return delegate?.holdEnded() ?? false
        }
    }

    /// Crossfades this pane from what the render server already has to whatever `change` leaves.
    ///
    /// The transition goes on BEFORE the change it covers and comes off again if the change turns
    /// out to have been nothing: an animation added and removed inside one run loop turn never
    /// reaches a frame. Everything `change` does happens in that same commit, which is what makes
    /// "the new layout is complete before the fade starts" true rather than hoped for.
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

    // MARK: - Arriving at another conversation

    /// **This pane has been pointed at another conversation, so it draws nothing until that one is
    /// ready.**
    ///
    /// The pane is not torn down by a workspace switch: the centre column hands the same view a
    /// different model and a different session, so without this the rows on screen for the moment
    /// after the switch are the conversation being left. Then the tail lands at the top of the
    /// pane, then the view jumps to the live end, then the history goes in behind it. Four states,
    /// three of which are a transcript nobody asked to see.
    ///
    /// So it is hidden until `arrived`, and what it shows meanwhile is its own background. Never
    /// the outgoing conversation, and never a picture of anything: an empty pane is honest, and it
    /// is the only thing that cannot be the wrong workspace's.
    func holdForArrival() {
        guard !isArriving else { return }
        // A resize hold has nothing left to protect, because the rows it was holding still belong
        // to the conversation being left. Cancelled rather than dropped: the table is held by a
        // flag of its own, and dropping this would leave it held for ever. Cancelled rather than
        // ENDED, and laid out on the next pass rather than this one, because this is called from
        // inside `updateNSView` and a reflow reports geometry, which writes SwiftUI state.
        if frozen != nil {
            frozen = nil
            letGo?.cancel()
            letGo = nil
            needsLayout = true
            delegate?.holdCancelled()
        }
        isArriving = true
        scroll.alphaValue = 0
        reveal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: TranscriptPaneHold.arrival)
            guard !Task.isCancelled else { return }
            self?.arrived()
        }
    }

    /// The conversation is in, and in the place the reader left it. See `TranscriptResume`.
    func arrived() {
        reveal?.cancel()
        reveal = nil
        guard isArriving else { return }
        isArriving = false
        fading {
            scroll.alphaValue = 1
            return true
        }
        TranscriptHoldCensus.revealed()
    }

    // MARK: - What says a gesture is running

    @objc private func handTookHold() {
        isUnderAHand = true
        if frozen != nil { armLetGo() }
    }

    @objc private func handLetGo() {
        isUnderAHand = false
        release()
    }

    /// The window's own edge, and any divider AppKit resizes panes for. Nothing is held here: the
    /// first width change is, so a window made taller freezes nothing.
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        TranscriptHoldCensus.liveResizeBegan()
        if frozen != nil { armLetGo() }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        release()
    }

    /// A pane put away mid drag must not come back holding a picture of the width it used to be.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        release()
    }
}
