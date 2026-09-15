import AppKit
import BloomCore
import QuartzCore

/// What a held transcript is asked to do. `TranscriptTable.Coordinator` is the only one.
@MainActor
protocol TranscriptHoldDelegate: AnyObject {
    /// The pane may be drawn again. Lay out whatever is owed before the fade shows it.
    func holdEnded()
    var reducesMotion: Bool { get }
}

/// **Holds a transcript back while its pane is pointed at a conversation that is not ready, and
/// fades to it when it is.**
///
/// An arrival is a workspace switch, a tab switch, the pane's first conversation, and a split,
/// whose pane is rebuilt rather than resized (see `CenterPanesView`, whose `ForEach` identity
/// deliberately changes when a tab goes from one pane to two).
///
/// **A resize is not held here.** This view used to keep the scroll view at its old frame for the
/// length of a drag and crossfade to the reflowed transcript at the end, when measuring a row cost
/// two milliseconds. It is a tenth of that now, so `TranscriptTableView` reflows on every width
/// change instead and the reader watches the text rewrap under the hand. See
/// `TranscriptPaneHold`.
///
/// ## What a hold draws
///
/// The pane's own background, and it takes no clicks. A pane is NOT torn down by a workspace
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
/// **Nothing held here can belong to another pane**, because nothing is kept: the pane draws its
/// own ground and no picture of anything. There is no store to look a pane up in and therefore no
/// way to reach the wrong one.
///
/// ## The fade, and letting go
///
/// The fade is a `CATransition` on this view's layer, for the same measurement: the render server
/// crossfades what it already has against the next commit, and everything the reveal does happens
/// in that commit, so the new layout is complete before a frame of the fade is drawn.
///
/// **Every hold is armed to let go by itself**, at `TranscriptPaneHold.arrival`, so a conversation
/// that never loads, a task cancelled on its way there and a session with nothing in it do not
/// leave a blank pane.
final class TranscriptHoldView: NSView {
    let scroll: NSScrollView
    weak var delegate: TranscriptHoldDelegate?

    /// Whether this pane is drawing its own ground in place of the transcript.
    private(set) var isHolding = false
    private var letGo: Task<Void, Never>?

    private static let fadeKey = "bloom.transcript.reveal"

    init(scroll: NSScrollView) {
        self.scroll = scroll
        super.init(frame: .zero)
        wantsLayer = true
        autoresizesSubviews = false
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    /// Nothing reaches a pane that is not being drawn. A wheel event during an arrival would take
    /// the standing instruction to be at the live end off a transcript nobody can see yet, and the
    /// reader would be somewhere they never scrolled to when it fades in.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHolding ? nil : super.hitTest(point)
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
    }

    /// **This pane has been pointed at a conversation that is not ready. Draw nothing until it
    /// is.** Idempotent: a second arrival before the first is revealed re-arms the deadline.
    func hold() {
        if isHolding {
            armLetGo()
            return
        }
        isHolding = true
        scroll.alphaValue = 0
        TranscriptHoldCensus.arrived()
        armLetGo()
    }

    /// **The one way out.** Lay out whatever is owed, and fade to it.
    func ready() {
        letGo?.cancel()
        letGo = nil
        guard isHolding else { return }
        isHolding = false
        fading {
            needsLayout = true
            layoutSubtreeIfNeeded()
            scroll.alphaValue = 1
            delegate?.holdEnded()
        }
        TranscriptHoldCensus.revealed()
    }

    private func armLetGo() {
        letGo?.cancel()
        letGo = Task { @MainActor [weak self] in
            try? await Task.sleep(for: TranscriptPaneHold.arrival)
            guard !Task.isCancelled else { return }
            self?.ready()
        }
    }

    /// Crossfades this pane from what the render server already has to whatever `change` leaves.
    /// The transition goes on BEFORE the change it covers, so the change lands in the same commit.
    private func fading(_ change: () -> Void) {
        let seconds = delegate?.reducesMotion == true ? 0 : Motion.revealSeconds
        if seconds > 0 {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = seconds
            layer?.add(fade, forKey: Self.fadeKey)
        }
        change()
    }
}
