import AppKit
import QuartzCore
import SwiftUI
import BloomCore

/// How wide the title bar's own strip has to be, which is the width of the pane under it.
///
/// The pull request strip sits in the title bar now, directly above the column it belongs to, and
/// a band that is a few points wider or narrower than the pane under it reads as a mistake rather
/// than as a heading. The width is not a constant: the split view remembers what it was dragged
/// to and hands the inspector a different number on every window size, so the only honest source
/// is the pane itself. `DetailSplitViewController` publishes it here on every layout pass.
///
/// It used to be two numbers added together, because the worktree's menu sat in the accessory
/// as well and only SwiftUI knew how wide that control came out. That menu is on the workspace's
/// own row in the sidebar now, so the accessory is the band and nothing else, and the second
/// number went with it rather than being left at zero for the next reader to wonder about. See
/// `WorkspaceRow.moreMenu`.
///
/// A collapsed inspector is the same fact said with a zero, rather than a second flag that can
/// disagree with the first: a hidden inspector has no width, and the strip above it has nothing to
/// be as wide as.
///
/// `onChange` is what makes an AppKit title bar accessory follow a SwiftUI number. An accessory is
/// laid out from its view's frame rather than from its intrinsic content size, measured on this
/// branch: with a 132 point intrinsic size the container kept the one point frame it was given. So
/// the frame is set by hand, and this is what says when.
///
/// **That frame is also the window's search field's x, which is why the accessory travels rather
/// than jumps.** The toolbar gets what the trailing accessory leaves it, and `.searchable`'s
/// `NSSearchToolbarItem` is packed against the end of it by `BloomWindowToolbar`'s flexible
/// spacer. See `TitleBarStripController.resize` and `InspectorSlide`.
@MainActor
@Observable
final class InspectorGeometry {
    static let shared = InspectorGeometry()

    /// The inspector pane's width in points, zero while it is collapsed.
    ///
    /// Where the pane is GOING rather than where the title bar is: for a quarter of a second after
    /// this is written the accessory is still on its way to it.
    private(set) var width: CGFloat = 0

    /// The width the band is DRAWN at, which is the last width the pane actually had.
    ///
    /// Not `width`, and the difference between them is what lets the band leave rather than
    /// vanish. A hide publishes a zero on the first frame of the transition, and a band drawn zero
    /// points wide has not slid out, it has gone. This number is only ever raised, so the band
    /// keeps its shape for the whole of the slide it is in the middle of.
    private(set) var bandWidth: CGFloat = Metrics.inspectorWidth

    /// Whether the title bar has any room for the band at all.
    ///
    /// Written by the accessory rather than derived from `width`, because the two answer different
    /// questions for as long as a slide is running: `width` is zero on the FIRST frame of a hide,
    /// and the band has a quarter of a second of leaving still to do inside an accessory that is
    /// still most of the way open. The band is mounted while the accessory has width and dropped
    /// the moment it has none, which is what keeps `PullRequestBar` from polling GitHub for a band
    /// nobody can see.
    private(set) var isVisible = false

    /// Called when the pane's width moves, and told whether the move is the column opening or
    /// collapsing rather than a divider drag, a window resize or a launch.
    ///
    /// Only a collapse is a slide. A drag has to stay live and a launch has to be instant, and both
    /// of those publish a width too. Reduce Motion arrives down this same wire, because the split
    /// view is the thing told not to animate and it then publishes `false`, so the window takes one
    /// decision about movement rather than two that can disagree.
    ///
    /// Not observation: the reader is an `NSView` frame.
    @ObservationIgnored var onChange: ((_ sliding: Bool) -> Void)?

    private init() {}

    func setInspectorWidth(_ value: CGFloat, sliding: Bool = false) {
        guard abs(width - value) > 0.5 else { return }
        width = value
        if value > 1 { bandWidth = value }
        onChange?(sliding)
    }

    /// Said by the accessory as it starts to open and again once it has finished closing. See
    /// `isVisible` for why the accessory is the one that knows.
    func setBandVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
    }
}

/// The trailing end of the title bar: the pull request this workspace's branch is heading for.
///
/// The strip used to sit lower, as the first row inside the inspector. It is the one thing about
/// a workspace with a state in it that changes without anybody touching Bloom, so it took the top
/// row and the window's edge, directly above the pane it is the heading for.
///
/// It shared the accessory with a chip for a while: `WindowTitleLabel`, the worktree's own menu,
/// which had given up the project's name and then the project's mark until it was the ellipsis
/// alone. The owner said the ellipsis was in the wrong place and should be on the workspace's row
/// in the sidebar, which is the thing it acts on, and its three items were already in that row's
/// menu word for word. So the chip is gone rather than moved, and this accessory is one view
/// again. See `WorkspaceRow.moreMenu`.
///
/// Nothing was rearranged to close the gap. The chip stood at the LEADING end of the accessory,
/// which is a trailing accessory, so the band was never displaced by it: taking it away lets the
/// band sit at the pane's edge where it already ended, and the space it held falls back to the
/// window title and its proxy icon, which is the run of title bar it was borrowing from.
///
/// `PullRequestBar` itself is drawn exactly as the inspector drew it, given the width of the pane
/// it is now the heading for.
///
/// **What the band cannot say, it says on hover.** 380 points with a Create pull request button
/// in them leaves the branch and the state a couple of dozen characters each, so the band reads
/// `…t-question` over `No pull reque…` on a name nobody would call long. Resting on it opens the
/// card the sidebar row opens, filled in for a pull request rather than for a workspace: see
/// `WorkspaceHoverCard.pullRequestBand`. Nothing new is fetched for it. Everything on it is what
/// `PullRequestBar` is already polling for the band itself.
struct TitleBarStrip: View {
    let app: AppModel

    /// The title bar's own height, measured off the window before this view was put in it.
    let height: CGFloat

    /// Where the band is on screen, for the card that hangs under it. Held rather than reported,
    /// for the reason on `HoverCardAnchor`, and needed here for a second reason besides: a title
    /// bar accessory is its own SwiftUI root, so a `GeometryReader` in it measures a space whose
    /// origin is the accessory's rather than the window's.
    @State private var anchor = HoverCardAnchor()

    /// The workspace the band is drawn for, which outlives the selection by one slide.
    ///
    /// `app.selectedModel` is nil the instant the window moves to Home, and the band has a quarter
    /// of a second of leaving still to do. It used to survive that on SwiftUI's own removal
    /// transition, which keeps a departing subtree alive for as long as the animation it is playing;
    /// the band plays none any more, because the accessory's frame carries it out now, so what the
    /// transition was holding has to be held here instead. The same shape as
    /// `InspectorGeometry.bandWidth` and for the same reason: a band on its way out is still a band.
    @State private var shown: WorkspaceModel?

    private var inspector: InspectorGeometry { .shared }

    var body: some View {
        Group {
            if let model = shown, inspector.isVisible {
                PullRequestBar(model: model)
                    // As wide as the pane below it, so the band ends where the pane does and the
                    // split divider runs out of the bottom of it. `bandWidth` rather than `width`
                    // because a band on its way out is still a band: see `InspectorGeometry`.
                    .frame(width: inspector.bandWidth, height: height)
                    .background { ground(for: model) }
                    .background { HoverCardAnchorReader(anchor: anchor) }
                    // The whole band is the target, button included, and that is a decision rather
                    // than the easy way to write it. The band is one subject: the branch, where it
                    // is going, and what GitHub says about it, with a button that acts on exactly
                    // that. A card that opened over the left two thirds and not the right third
                    // would be an affordance you have to find. What keeps it from firing on a
                    // pointer crossing the band on its way to that button is the wait, which is
                    // `Motion.hoverCardDelay` and is the same 350ms the sidebar rests for.
                    //
                    // The card hangs BELOW, so it never covers the thing it was opened from, and
                    // it takes no clicks, so it cannot come between the pointer and the button.
                    // Both of those are the panel's, not this view's: see the presenter.
                    //
                    // Whether hover works at all in a title bar accessory is the one thing here
                    // that was reasoned rather than measured, and it is written down as reasoning
                    // so the next reader knows to check it. The accessory is a real `NSView` in
                    // the window's title bar container, so SwiftUI installs its tracking area the
                    // ordinary way, and what AppKit reserves in that band is the window DRAG,
                    // which is a mouse-down gesture rather than a tracking one. The head of
                    // `TitleBarStripController` measured the neighbouring half of that: a click on
                    // a control here reaches the control and a drag on the band's background still
                    // moves the window. If the card never opens, this is the line to doubt first,
                    // and an `NSTrackingArea` on the hosting view is the way out.
                    .onHoverChange { inside in
                        let source = WorkspaceHoverCardPresenter.Source
                            .pullRequestBand(model.workspace.id)
                        if inside {
                            WorkspaceHoverCardPresenter.shared.pointerEntered(
                                source,
                                card: { bandCard(for: model) },
                                anchor: { anchor.screenFrame },
                                side: .below
                            )
                        } else {
                            WorkspaceHoverCardPresenter.shared.pointerExited(source)
                        }
                    }
                    // The band leaves under a stationary pointer whenever the inspector is
                    // collapsed or the selection moves to Home, and neither of those sends an
                    // exit. The sidebar row keeps this for the same reason.
                    .onDisappear {
                        WorkspaceHoverCardPresenter.shared
                            .pointerExited(.pullRequestBand(model.workspace.id))
                    }
            }
        }
        // The band is drawn at the width the PANE settles at, inside an accessory whose own width
        // is travelling, so the two numbers disagree for the whole of every slide. This is which
        // edge wins: the band keeps its leading edge rather than being centred in a frame it has
        // outgrown, and the accessory clips the rest.
        //
        // **That is the whole of the band's movement now, and there is no transition here any
        // more.** The accessory's trailing edge is the window's, so shrinking it walks its leading
        // edge towards that corner and the band goes with it, clipped as it passes the edge, which
        // is exactly what the pane below is doing. A `.transition(.offset)` on top of that would be
        // the same distance travelled twice: the band left in the first half of the slide and
        // arrived in the second. Gluing the band to the edge the accessory gives back also glues it
        // to the search field, which is packed against that same edge from the other side, so the
        // two things in the title bar cannot drift apart no matter what clock either is on.
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .overlay(alignment: .leading) { Hairline(axis: .vertical) }
        // The model's identity rather than its row: a workspace row is rewritten every six seconds
        // by the diff stat refresh, and the only thing this needs to hear about is the band being
        // for a different workspace. `initial` seeds it for a window that comes up on one.
        .onChange(of: app.selectedModel.map { ObjectIdentifier($0) }, initial: true) { _, _ in
            if let model = app.selectedModel { shown = model }
        }
        // The end of a slide out is the moment the departing band can be let go of. Taken from the
        // selection rather than set to nil, because the inspector can also be closed with a
        // workspace still selected, and that band should come back with the pane.
        .onChange(of: inspector.isVisible) { _, visible in
            if !visible { shown = app.selectedModel }
        }
        // A separate SwiftUI root: the window's environment does not reach a title bar accessory,
        // so the model is handed in rather than inherited.
        .environment(app)
    }

    /// What the card says, built at the moment it opens rather than on every redraw.
    ///
    /// **Nothing in here fetches.** The pull request is whatever `PullRequestBar`'s own poll last
    /// brought back and the local counts are whatever the inspector last read, which are the two
    /// facts the band beside it is already drawn and tinted from. A hover that started a `gh` call
    /// would put a subprocess behind moving the pointer across the top of the window.
    private func bandCard(for model: WorkspaceModel) -> WorkspaceHoverCard {
        WorkspaceHoverCard.pullRequestBand(
            workspace: model.workspace,
            pullRequest: model.pullRequest,
            localWork: model.localWork
        )
    }

    /// The four points the title bar is taller than the strip.
    ///
    /// `PullRequestBar` draws its ground inside a frame of exactly
    /// `InspectorLayout.pullRequestBarHeight`, which is 48, and the title bar of a window with a
    /// unified toolbar measures 52. Those four points would otherwise be window chrome along the
    /// top edge of a band whose whole job is to BE the top edge of the window: invisible on a
    /// merged pull request, which washes the surface by eight percent, and plainly a mistake on an
    /// open one, where the band is eighteen percent of amber and the ledge above it is the grey of
    /// the sidebar.
    ///
    /// The only thing in this file that repeats anything from the strip, and it repeats the ground
    /// rather than the strip: the same tone off `PullRequestStatus`, the same two opacities out of
    /// `InspectorLayout`. A tint that changes there changes here.
    @ViewBuilder
    private func ground(for model: WorkspaceModel) -> some View {
        ZStack {
            Palette.surface
            if let tint = model.pullRequest?.status(local: model.localWork).tone.color {
                tint.opacity(
                    model.pullRequest?.isOpen == false
                        ? InspectorLayout.bandOpacityQuiet
                        : InspectorLayout.bandOpacity
                )
            }
        }
    }
}

/// Puts `TitleBarStrip` in the title bar itself.
///
/// A title bar accessory, rather than content drawn under a transparent title bar in a
/// `fullSizeContentView` window. The second way puts the content UNDER AppKit's own title bar
/// view, which is the view that a click in that band reaches, and the strip carries buttons: the
/// pull request's own, and the merge. An accessory is the supported way of putting real controls
/// in a title bar, and on this branch it behaves like one: a real click on a control in the band
/// reaches it, and a real drag on the band's own background still moves the window. Both were
/// measured, not assumed.
///
/// `.trailing` puts it at the trailing end of the title bar, after the toolbar's items, which is
/// the edge the inspector is against.
@MainActor
final class TitleBarStripController: NSTitlebarAccessoryViewController {
    private let height: CGFloat

    /// The slide in progress and the clock it is measured against, or nil at rest. See `resize`.
    private var slide: InspectorSlide?
    private var startedAt: CFTimeInterval = 0
    private var frames: CADisplayLink?

    init(app: AppModel, height: CGFloat) {
        self.height = height
        super.init(nibName: nil, bundle: nil)

        let host = NSHostingView(rootView: TitleBarStrip(app: app, height: height))

        // No size travels out of SwiftUI here, for the same reason it does not in the split view's
        // panes: the accessory container sets this view's frame, and an intrinsic content size only
        // gives autolayout a second opinion about it.
        host.sizingOptions = []
        // The band slides in and out THROUGH this frame, so for a quarter of a second at each end
        // it is drawn beyond the accessory's trailing edge. That edge is the window's, so the
        // window would clip it anyway; clipping here says so rather than relying on it, and costs
        // nothing at rest because the band is exactly this view's size once it has arrived.
        host.clipsToBounds = true
        view = host
        layoutAttribute = .trailing
        // What the accessory keeps while the title bar is in its full screen state. Without it the
        // strip is the one thing in the title bar that can be given no height at all.
        fullScreenMinHeight = height

        InspectorGeometry.shared.onChange = { [weak self] sliding in self?.resize(sliding: sliding) }
        resize(sliding: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not decoded from a nib") }

    /// Follows the pane's width, over a quarter of a second when the pane is sliding and this frame
    /// when it is not.
    ///
    /// One point rather than zero when there is nothing to show, so the accessory is never a view
    /// of no size at all in the title bar's layout. On Home and on Search that is what it is.
    ///
    /// **This used to jump, and what it dragged with it was the search field.** The toolbar is laid
    /// out in what the trailing accessory leaves it, and `BloomWindowToolbar`'s flexible spacer
    /// packs `.searchable`'s item against the end of that, so the field sits exactly where this
    /// frame's leading edge puts it: measured offscreen at 1440 points with the accessory at 380,
    /// the field's capsule is at x=727, and with the accessory at one point it has 379 more points
    /// to travel into. Setting the frame in one step therefore moved the field 379 points in one
    /// frame while the pane spent `Motion.inspectorSeconds` sliding underneath it, and the old
    /// version made it worse in the other direction: a hide waited out the whole slide and then
    /// jumped, so the field moved a quarter of a second after everything else had stopped.
    ///
    /// No toolbar API animates that, and none is needed. An `NSToolbar` re-packs its items whenever
    /// the space it is given changes, which is what it does on every frame of a live window resize.
    /// So the frame is walked to its new width a frame at a time and the toolbar tracks it, the way
    /// it tracks a resize. `InspectorSlide` is the arithmetic, and it is on the same cubic and the
    /// same length as the split view's animation context, so the pane, the band and the field are
    /// three parts of one movement rather than three movements.
    ///
    /// Only a collapse travels. A divider drag publishes `sliding` false and has to stay live, or
    /// the band trails the divider by a quarter of a second the whole time it is being dragged, and
    /// Reduce Motion arrives the same way: the split view is told not to animate and publishes no
    /// slide.
    private func resize(sliding: Bool) {
        let target = max(InspectorGeometry.shared.width, 1)
        // A view with no window has no display to take a link from, and a slide whose clock never
        // ticks is an accessory stuck at the width it set off from. Nothing can be watching such a
        // window anyway, so it lands rather than travels. This is also the first call, from `init`.
        guard sliding, view.window != nil else {
            endSlide()
            InspectorGeometry.shared.setBandVisible(target > 1)
            apply(target)
            return
        }
        startSlide(to: target)
    }

    /// Starts from where the accessory actually is rather than from where it should have been, so a
    /// hide reversed halfway travels back from halfway rather than snapping open first.
    private func startSlide(to target: CGFloat) {
        // A target the accessory is already at ends whatever was running rather than being ignored:
        // that is a hide reversed at the exact point it had reached, and the slide it was on is no
        // longer going anywhere this window wants.
        guard abs(view.frame.width - target) > 0.5 else {
            endSlide()
            return
        }
        // Mounted before the first step rather than when the width crosses a point, so the band has
        // been laid out by the time there is enough accessory to see any of it in.
        if target > 1 { InspectorGeometry.shared.setBandVisible(true) }
        slide = InspectorSlide(
            from: view.frame.width, to: target, seconds: Motion.inspectorSeconds
        )
        startedAt = CACurrentMediaTime()
        guard frames == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        frames = link
    }

    /// `targetTimestamp` rather than the clock, because it is when the frame being laid out here
    /// will be SHOWN, and that is what Core Animation and SwiftUI interpolate the other two thirds
    /// of this movement against. Reading the clock at the callback instead runs a frame behind them,
    /// which at the fastest part of the curve is a dozen points of daylight at the band's edge.
    @objc private func step(_ sender: CADisplayLink) {
        guard let slide else {
            endSlide()
            return
        }
        let elapsed = sender.targetTimestamp - startedAt
        apply(slide.width(after: elapsed))
        guard slide.hasFinished(after: elapsed) else { return }
        InspectorGeometry.shared.setBandVisible(slide.to > 1)
        endSlide()
    }

    private func endSlide() {
        slide = nil
        frames?.invalidate()
        frames = nil
    }

    /// The epsilon is a point of a point rather than half a point, because the last few steps of an
    /// ease are smaller than that and one of them is the one that lands on the final width.
    private func apply(_ width: CGFloat) {
        guard abs(view.frame.width - width) > 0.01 else { return }
        view.setFrameSize(NSSize(width: width, height: height))
        view.superview?.needsLayout = true
    }
}
