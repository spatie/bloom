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
    var reducesMotion: Bool { get }
}

/// Holds the transcript still while a pane is being resized, and fades to the reflowed one when it
/// stops.
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
/// `TranscriptResizeHold.quiet` after the last width change, which is 200ms. Nothing here needs an
/// end event to arrive, which is why it is safe to hold for gestures that do not send one.
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

    private static let fadeKey = "bloom.transcript.reflow"

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
        guard window != nil else { return }
        guard TranscriptResizeHold.holds(from: Double(before), to: Double(width)) else { return }
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
        let deadline = TranscriptResizeHold.letsGo(underAHand: isUnderAHand || inLiveResize)
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

        // Added before the change it covers, and taken off again if there turns out to be nothing
        // to cover: an animation added and removed inside one run loop turn never reaches a frame.
        let seconds = delegate?.reducesMotion == true ? 0 : Motion.reflowSeconds
        if seconds > 0 {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = seconds
            layer?.add(fade, forKey: Self.fadeKey)
        }

        needsLayout = true
        // The scroll view takes the pane's width here, which is what tells the table it moved.
        layoutSubtreeIfNeeded()
        let moved = delegate?.holdEnded() ?? false
        if !moved { layer?.removeAnimation(forKey: Self.fadeKey) }
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
