import AppKit
import BloomCore
import SwiftUI
import QuartzCore

/// How long each pane spent in layout, while `FrameProbe` is measuring a drag.
///
/// Off unless a probe turned it on, and it reads one clock and adds to two doubles when it is on,
/// so nothing here is a cost the shipping app pays. It exists because "the drag is slow" and "the
/// centre column's layout is slow" are different claims, and only the second one can be acted on.
@MainActor
enum PaneLayoutTiming {
    static var isEnabled = false
    private static var counts: [String: Int] = [:]
    private static var seconds: [String: Double] = [:]

    /// When each pass started, measured from `reset`, and how long it took. A total says a switch
    /// is expensive; the passes say it is expensive four times over, which is a different problem
    /// with a different fix.
    private static var passes: [String: [[Double]]] = [:]
    private static var origin: Double = 0

    static func reset() {
        counts.removeAll()
        seconds.removeAll()
        passes.removeAll()
        origin = CACurrentMediaTime()
    }

    static func record(_ pane: String, _ elapsed: Double) {
        counts[pane, default: 0] += 1
        seconds[pane, default: 0] += elapsed
        passes[pane, default: []].append([
            (CACurrentMediaTime() - elapsed - origin) * 1000, elapsed * 1000,
        ])
    }

    /// Every pass, as `[startedMs, tookMs]`, for a report that has to say when as well as how long.
    static func timeline() -> [String: [[Double]]] { passes }

    static func summary() -> [String: [String: Double]] {
        var result: [String: [String: Double]] = [:]
        for (pane, total) in seconds {
            let count = Double(counts[pane] ?? 0)
            result[pane] = [
                "passes": count,
                "totalMs": total * 1000,
                "meanMs": count > 0 ? total * 1000 / count : 0,
            ]
        }
        return result
    }
}

/// An `NSHostingView` that can be asked how long its layout took. See `PaneLayoutTiming`.
private final class MeasuredHostingView: NSHostingView<AnyView> {
    var paneName = ""

    override func layout() {
        guard PaneLayoutTiming.isEnabled else { return super.layout() }
        let started = CACurrentMediaTime()
        super.layout()
        PaneLayoutTiming.record(paneName, CACurrentMediaTime() - started)
    }
}

/// Fills the pane with its host without an Auto Layout solve for every divider position.
private final class PaneContainerView: NSView {
    private let host: NSView
    private let minimumWidth: CGFloat
    private let pinsTrailingEdge: Bool
    private static let resizeFadeKey = "bloom.pane.resize"
    var reflowStep: CGFloat? {
        didSet { fitHost() }
    }
    private var settledWidth: CGFloat = 0
    private var isSettled = true
    private var settleWork: Task<Void, Never>?

    init(host: NSView, minimumWidth: CGFloat, pinsTrailingEdge: Bool) {
        self.host = host
        self.minimumWidth = minimumWidth
        self.pinsTrailingEdge = pinsTrailingEdge
        super.init(frame: .zero)
        clipsToBounds = true
        wantsLayer = true
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not decoded from a nib") }

    override func setFrameSize(_ newSize: NSSize) {
        let widthMoved = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthMoved, newSize.width > 0 {
            isSettled = settledWidth == 0
            if isSettled { settledWidth = newSize.width }
            if !isSettled { settleAfterResize() }
            if !pinsTrailingEdge, newSize.width > settledWidth { needsDisplay = true }
        }
        fitHost()
    }

    override func draw(_ dirtyRect: NSRect) {
        // The held centre host can be narrower than its pane while the inspector moves away.
        // Fill that exposed strip with the same ground as the transcript, not the split view's gray.
        if !pinsTrailingEdge {
            Palette.surfaceNSColor.setFill()
            dirtyRect.fill()
        }
    }

    override func layout() {
        super.layout()
        fitHost()
    }

    private func fitHost() {
        // Hold the centre host at its last settled width during either divider drag. The inspector
        // reflows in small steps so its content stays beside its divider. Round up and clip the
        // excess there: rounding down exposes a gray strip inside the inspector.
        let width: CGFloat
        if isSettled || bounds.width < minimumWidth {
            width = bounds.width
        } else if let reflowStep {
            width = max(minimumWidth, ceil(bounds.width / reflowStep) * reflowStep)
        } else {
            width = settledWidth
        }
        let x = pinsTrailingEdge ? bounds.maxX - width : bounds.minX
        let wanted = NSRect(x: x, y: bounds.minY, width: width, height: bounds.height)
        if host.frame != wanted { host.frame = wanted }
    }

    /// A width that arrived at once rather than along a drag, taken as it is. Held and faded in
    /// 150 ms later, an inspector appearing with a workspace drew the transcript twice.
    func settleNow() {
        settleWork?.cancel()
        settleWork = nil
        guard bounds.width > 0 else { return }
        isSettled = true
        settledWidth = bounds.width
        fitHost()
    }

    private func settleAfterResize() {
        settleWork?.cancel()
        settleWork = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            settleWork = nil
            if !pinsTrailingEdge,
               abs(host.frame.width - bounds.width) > 0.5,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                // The render server crossfades the old and new layout without asking SwiftUI to
                // draw intermediate widths. The transcript and composer keep their identity.
                let fade = CATransition()
                fade.type = .fade
                fade.duration = Motion.revealSeconds
                layer?.add(fade, forKey: Self.resizeFadeKey)
            }
            isSettled = true
            settledWidth = bounds.width
            fitHost()
            host.layoutSubtreeIfNeeded()
        }
    }
}

/// A pane: an `NSHostingView` wrapped in a view controller so a split item can hold it.
///
/// Deliberately not an `NSHostingController`. That type exists to carry SwiftUI's measured size out
/// into AppKit through `sizingOptions` and `preferredContentSize`, and a split child controller
/// reading a measured size back into its item's thickness is the loop that kills this window. A
/// plain controller around an `NSHostingView` has no such channel at all: the pane fills whatever
/// the split view gives it, and nothing SwiftUI measures ever travels back the other way.
final class PaneViewController: NSViewController {
    private let host: MeasuredHostingView

    /// See `PaneContainerView.settleNow`.
    func settleNow() { (view as? PaneContainerView)?.settleNow() }

    var rootView: AnyView {
        get { host.rootView }
        set { host.rootView = newValue }
    }

    init(rootView: AnyView, name: String) {
        host = MeasuredHostingView(rootView: rootView)
        host.paneName = name
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not decoded from a nib") }

    override func loadView() {
        // The host has no intrinsic sizing options below, so it cannot push a measured SwiftUI
        // size back out. The container sets its frame directly during layout.
        // No size travels out of SwiftUI. An `NSHostingView` publishes its content's ideal size as
        // an intrinsic content size, and the split view's autolayout then refuses to make the pane
        // any narrower than that. Measured on this branch: the inspector pane published 622 and the
        // centre column 519, so the split view stopped shrinking at 801 and overflowed a 702 point
        // container, hanging the inspector's trailing edge and its Create Pull Request button off
        // the side of the window at the window's own minimum size. `minimumThickness` on the two
        // items is the real floor and it is a required constraint, so nothing is lost by silencing
        // this one.
        host.sizingOptions = []
        let inspector = host.paneName == "inspector"
        let container = PaneContainerView(
            host: host,
            minimumWidth: inspector
                ? DetailSplitViewController.inspectorMinimum : DetailSplitViewController.detailMinimum,
            pinsTrailingEdge: inspector
        )
        container.reflowStep = inspector ? 16 : nil
        view = container
    }
}

/// The boundary between the centre column and the inspector, owned by AppKit.
///
/// The hand-built version of this was an `HStack` holding a `PaneDivider`, arithmetic that clamped
/// the inspector against a continuously measured detail width, and an `@AppStorage` for the width.
/// All of it existed because `.inspector()` crashes this window and `HSplitView` draws its rule
/// through the title. An `NSSplitViewController` is neither, and the minimum widths, the collapse,
/// the remembered divider position and the divider itself are the framework's rather than ours.
///
/// The crash `.inspector()` throws is a feedback loop, and the loop runs through SwiftUI's own
/// `SplitViewChildController`: it observes its hosting view's minimum and maximum size and answers
/// a change by invalidating layout, which produces another minimum and maximum size. Every
/// thickness here is a constant, and `PaneViewController` gives SwiftUI no way to report a size
/// back at all, so there is nothing for such a loop to run through.
final class DetailSplitViewController: NSSplitViewController {
    private let detailHost: PaneViewController
    private let inspectorHost: PaneViewController
    private var inspectorItem: NSSplitViewItem!
    /// AppKit may report an expanded frame during restoration or a closing animation.
    /// Those frames must not reopen the title-bar band after the app has hidden the pane.
    private var isInspectorPresented = false
    private var isUpdating = false
    /// AppKit can choose a new divider position when an item is expanded after showing a
    /// conversation. Keep the width that was on screen before the collapse.
    private var inspectorWidthBeforeCollapse: CGFloat?
    private var needsInspectorWidthRestore = false
    private var collapseObservation: NSKeyValueObservation?
    var onInspectorPresentationChanged: ((Bool) -> Void)?

    /// What the centre column refuses to go below. The inspector's ceiling is the other side of the
    /// same coin, and AppKit derives it rather than us: with both minimums declared a drag simply
    /// stops, where the SwiftUI version had to recompute a ceiling from a measured width on every
    /// layout to stop the split view squeezing the sidebar instead.
    static let detailMinimum: CGFloat = 420
    static let inspectorMinimum: CGFloat = 280
    private static let inspectorMaximum: CGFloat = 760

    // The narrowest this half of the window can be drawn is `BloomApp.widths.detailHalf`, and it
    // is not a constant here any more, because it is not a constant: a collapsed inspector takes no
    // room and the window should not be held to a width for it. The two numbers above are what that
    // is built out of, and they are hard AppKit constraints rather than preferences: below the sum
    // of them the split view stops laying out and starts clipping, and nothing above it in SwiftUI
    // negotiates the difference away.

    private static let autosaveName = "bloom.detail.split"

    /// What the detail column was showing when `update` last ran, or nil before the first one.
    ///
    /// Kept only so that "the pane is being swapped" can be told from "the inspector is being
    /// toggled over the same pane", which is the difference `InspectorTransition` turns into an
    /// answer. Read its head: one of those two crashes and the other does not.
    private var lastContent: SidebarSelection?

    init(detail: AnyView, inspector: AnyView) {
        detailHost = PaneViewController(rootView: detail, name: "detail")
        inspectorHost = PaneViewController(rootView: inspector, name: "inspector")
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not decoded from a nib") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.minimumThickness = Self.detailMinimum
        // The centre column is the one that absorbs a window resize, which is what a low holding
        // priority means. Without it, widening the window widens the inspector.
        detailItem.holdingPriority = .init(NSLayoutConstraint.Priority.defaultLow.rawValue)
        detailItem.canCollapse = false

        // A plain item rather than `NSSplitViewItem(inspectorWithViewController:)`. The inspector
        // flavour wraps its pane in a vibrancy context: the hosted view comes out reporting
        // `NSAppearanceNameVibrantLight` where the window and the centre pane report `Aqua`, and
        // every semantic colour inside the pane then resolves to its vibrant variant. Bloom's
        // inspector paints its own opaque backgrounds, so the material underneath is never seen and
        // all the vibrancy does is shift the ink drawn on top of it. What the flavour otherwise
        // gives is a trailing edge, a width that survives a window resize, and a collapse, and
        // those are the lines below.
        //
        // The starting width comes from the view's own frame, set before the item wraps it. An item
        // with nothing stating a width settles on its minimum, because the centre column's low
        // holding priority means the centre column is handed every point of slack, and the
        // inspector then opened at 280 where it has always opened at 380. Neither
        // `preferredContentSize` nor `setPosition(_:ofDividerAt:)` moves an item inside an
        // `NSSplitViewController`; both were measured, and both left it at 280.
        inspectorHost.view.setFrameSize(NSSize(width: Metrics.inspectorWidth, height: 0))
        inspectorItem = NSSplitViewItem(viewController: inspectorHost)
        inspectorItem.minimumThickness = Self.inspectorMinimum
        inspectorItem.maximumThickness = Self.inspectorMaximum
        inspectorItem.canCollapse = true
        // Higher than the centre column's, so a window resize moves the centre boundary and leaves
        // the inspector at the width it was dragged to. A hair higher, not `defaultHigh`: a
        // holding priority is a width constraint at that priority, and at 750 it outranked the pin
        // SwiftUI's representable host puts on this view, so the split view kept the width it had
        // and overflowed the column instead of shrinking the inspector to its minimum. 260 is what
        // AppKit itself gives a sidebar item.
        inspectorItem.holdingPriority = .init(260)

        addSplitViewItem(detailItem)
        addSplitViewItem(inspectorItem)

        // `.thin` is left exactly as AppKit sets it, and that is the point.
        //
        // The rule we used to draw was `Metrics.hairline` of `Palette.border`, which measures one
        // physical pixel at brightness 234 on white. The system divider is also one physical pixel
        // and measures 211, so it carries twice the contrast against the same ground, and on dark
        // it inverts to 14 against a 40 background instead of holding a light-mode value. It also
        // brings a grab area wider than the line, which is what `PaneDivider` reimplemented with a
        // `Metrics.spacingWide` strip. `.thick` and `.paneSplitter` are the old heavy dividers with
        // a dimple; nothing that puts a source list beside content on this system uses them.
        splitView.dividerStyle = .thin
        splitView.identifier = NSUserInterfaceItemIdentifier("bloom.detail.inspector.split")

        // Replaces the `@AppStorage("inspector.width")` the SwiftUI version kept by hand.
        splitView.autosaveName = Self.autosaveName

        watchInspectorWidth()
        // A divider drag changes the native item without going through `update`. Frame
        // notifications alone miss a collapse when AppKit keeps the pane's previous frame.
        collapseObservation = inspectorItem.observe(\.isCollapsed) { [weak self] _, _ in
            // AppKit changes this split item on the main thread, including during a drag.
            MainActor.assumeIsolated { self?.inspectorCollapseChanged() }
        }
    }

    private func inspectorCollapseChanged() {
        guard lastContent != nil, !isUpdating else { return }
        let presented = !inspectorItem.isCollapsed
        // `update` sets this before asking AppKit to collapse, so only native changes come back.
        guard presented != isInspectorPresented else { return }
        isInspectorPresented = presented
        // Update the model before publishing geometry. Deferring this let a SwiftUI refresh
        // reapply the old state, so the next toolbar click tried to close an already hidden pane.
        onInspectorPresentationChanged?(presented)
        publishInspectorWidth(collapsed: !presented, sliding: false)
    }

    /// Tells the title bar how wide the inspector currently is.
    ///
    /// The pull request strip sits above this pane now rather than inside it, and a band that does
    /// not end where the pane ends reads as a misalignment rather than as a heading.
    ///
    /// Both notifications matter: the pane can resize, or the split view can clip its container
    /// while leaving the pane's frame unchanged. `viewDidLayout` missed divider drags entirely.
    private func watchInspectorWidth() {
        inspectorHost.view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneFrameChanged),
            name: NSView.frameDidChangeNotification,
            object: inspectorHost.view
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneFrameChanged),
            name: NSSplitView.didResizeSubviewsNotification,
            object: splitView
        )
    }

    /// A drag or a resize. Never a slide: the pane is where it is, and the title bar should follow
    /// it this frame rather than a quarter of a second from now.
    @objc private func paneFrameChanged() {
        if needsInspectorWidthRestore { restoreInspectorWidth() }
        // AppKit can shrink the item's container while its hosted view keeps its minimum width.
        // The header follows the part still visible, including a drag that clips it to zero.
        let visibleWidth = inspectorHost.view.visibleRect.width
        let collapsed = !isInspectorPresented || inspectorItem.isCollapsed || visibleWidth <= 0
        let width = collapsed ? 0 : visibleWidth + splitView.dividerThickness
        InspectorGeometry.shared.setInspectorWidth(width, sliding: false)
    }

    /// `collapsed` is passed in rather than read back off the item, because the animated setter
    /// below is told where the pane is going and "where is it now" is a question with two
    /// defensible answers while it is on its way there.
    private func publishInspectorWidth(collapsed: Bool, sliding: Bool) {
        let width = collapsed ? 0 : inspectorHost.view.frame.width + splitView.dividerThickness
        InspectorGeometry.shared.setInspectorWidth(width, sliding: sliding)
    }

    func update(
        isInspectorPresented: Bool,
        animated: Bool,
        content: SidebarSelection
    ) {
        isUpdating = true
        defer { isUpdating = false }
        self.isInspectorPresented = isInspectorPresented

        // The hosted roots are deliberately not reassigned here. Both read the shared observable
        // `AppModel`, so replacing either root on every selection discarded its entire SwiftUI
        // graph and every native view under it before Observation could update anything in place.
        // On a warm workspace switch that was 100 to 180ms of main-thread graph and layout work,
        // including a blank frame between the two transcripts. See `SelectedInspectorPane` and
        // `DetailColumn`, which are the stable roots.
        //
        // What remains here is whether an inspector collapse may animate. That still needs to know
        // whether the selection changed, because `InspectorTransition` carries the crash this
        // distinction prevents.
        let isFirstUpdate = lastContent == nil
        let contentIsChanging = lastContent != nil && lastContent != content
        lastContent = content
        let animated = InspectorTransition.isAnimated(
            motionAllowed: animated && !isFirstUpdate, contentIsChanging: contentIsChanging
        )

        let shouldCollapse = !isInspectorPresented
        guard inspectorItem.isCollapsed != shouldCollapse else {
            // The restored native state can already be correct while the title bar still holds
            // an earlier width. An unchanged collapse still needs to reconcile that geometry.
            paneFrameChanged()
            return
        }
        if shouldCollapse {
            inspectorWidthBeforeCollapse = inspectorHost.view.frame.width
        }
        if !shouldCollapse { makeRoomForInspector(animated: animated) }
        // The animated setter runs a layout pass on every frame of the transition, and layout churn
        // is the condition this window has crashed under, so Reduce Motion turns it off rather than
        // merely shortening it.
        guard animated else {
            inspectorItem.isCollapsed = shouldCollapse
            if !shouldCollapse {
                needsInspectorWidthRestore = inspectorWidthBeforeCollapse != nil
                restoreInspectorWidth()
            }
            publishInspectorWidth(collapsed: shouldCollapse, sliding: false)
            splitView.layoutSubtreeIfNeeded()
            detailHost.settleNow()
            return
        }

        // The three parts of the inspector, started together.
        //
        // What the user reads as one thing arriving is drawn by two frameworks: this pane, and the
        // pull request band, which is a title bar accessory because it sits in the title bar rather
        // than in the pane. The band used to be drawn or not drawn with nothing in between, so it
        // appeared whole on the frame the toolbar button was pressed while the pane slid in
        // underneath it a quarter of a second later. Reported as "bit jarring now", and it was two
        // events rather than one.
        //
        // So both are started inside one animation context, off one duration. The context is given
        // its numbers rather than left at its defaults for the same reason the band is told about
        // the slide at all: a length nobody wrote down is a length the parts are free to disagree
        // about later. `Motion.inspectorSeconds` is what the default already was, so the pane keeps
        // exactly the speed it has always collapsed at.
        //
        // The third part is the window's search field, and it moves because the band's accessory is
        // what decides how much title bar the toolbar gets. It is not mentioned in this call because
        // nothing here has to mention it: it follows the accessory, the accessory follows this
        // publish, and `TitleBarStripController.resize` is where that is written down.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.inspectorSeconds
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            inspectorItem.animator().isCollapsed = shouldCollapse
            publishInspectorWidth(collapsed: shouldCollapse, sliding: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if !shouldCollapse {
                    self?.needsInspectorWidthRestore = self?.inspectorWidthBeforeCollapse != nil
                    self?.restoreInspectorWidth()
                }
            }
        }
    }

    private func restoreInspectorWidth() {
        guard needsInspectorWidthRestore, isInspectorPresented, !inspectorItem.isCollapsed,
              let width = inspectorWidthBeforeCollapse else { return }
        needsInspectorWidthRestore = false
        splitView.layoutSubtreeIfNeeded()
        let available = splitView.bounds.width - Self.detailMinimum - splitView.dividerThickness
        guard available >= Self.inspectorMinimum else {
            needsInspectorWidthRestore = true
            return
        }
        let restored = min(max(width, Self.inspectorMinimum), min(available, Self.inspectorMaximum))
        splitView.setPosition(splitView.bounds.width - restored - splitView.dividerThickness, ofDividerAt: 0)
    }

    /// Widens the window, if it has to be widened, for a pane that is about to arrive in it.
    ///
    /// **This is what makes a conditional minimum honest rather than a trap.** The window's minimum
    /// drops by 281 points while the inspector is away, which is the whole point of the change, and
    /// the user is then free to drag the window down to it. Raising the minimum back up does not
    /// move a window: `NSWindow` applies a new minimum to what the USER does next, not to where the
    /// window already is. So without this the inspector would open into 281 points that do not
    /// exist, and the split view would lay out wider than its container and clip, which is exactly
    /// the defect the flat 1122 was introduced to stop.
    ///
    /// Growing the window is the same answer Notes and Freeform give to opening a sidebar in a
    /// window too small for one. What happens when the screen cannot afford it is
    /// `WindowWidths.presenting`'s decision rather than this method's: the window takes what the
    /// screen has and the first column gives up the rest, because a list of rows survives being
    /// narrow and a transcript and a diff do not.
    ///
    /// Inside the caller's animation context rather than before it, so the window grows over the
    /// same quarter of a second the pane slides in over. `setFrame(_:display:animate:)` would be
    /// the other way to animate it and it is the wrong one: it spins its own run loop and blocks
    /// the main thread for the length of the animation, in the middle of a collapse this window
    /// has crashed under layout churn during.
    private func makeRoomForInspector(animated: Bool) {
        guard let window = view.window, let screen = window.screen ?? NSScreen.main else { return }
        let content = window.contentRect(forFrameRect: window.frame).width
        let fit = BloomApp.widths.presenting(
            windowWidth: content, screenWidth: screen.visibleFrame.width
        )
        guard let wanted = fit.windowWidth else { return }

        var frame = window.frame
        frame.size.width += wanted - content
        // Grow to the right where there is room, and pull the leading edge in where there is not.
        // A window that grew off the side of the screen would be one whose inspector had arrived
        // somewhere the user cannot see, which is worse than the width it was opened at.
        if frame.maxX > screen.visibleFrame.maxX {
            frame.origin.x = max(screen.visibleFrame.minX, screen.visibleFrame.maxX - frame.width)
        }
        if animated {
            window.animator().setFrame(frame, display: true)
        } else {
            window.setFrame(frame, display: true)
        }
    }
}

/// Puts the split controller above back into the SwiftUI tree, at the detail position of the
/// window's `NavigationSplitView`.
///
/// The sidebar deliberately stays SwiftUI. Its translucent material, the toggle in the toolbar and
/// the traffic light placement all come free from `NavigationSplitView`, and none of them is worth
/// rebuilding in order to own a divider we already have.
struct DetailSplitView: NSViewControllerRepresentable {
    var app: AppModel
    var isInspectorPresented: Bool
    var animated: Bool

    func makeNSViewController(context: Context) -> DetailSplitViewController {
        DetailSplitViewController(detail: detail, inspector: inspector)
    }

    /// What this pane will accept, rather than what it currently measures.
    ///
    /// Without it SwiftUI asks the controller's view for its `fittingSize`, and an `NSSplitView`
    /// answers that with the width it is at: the inspector holds its thickness at a high priority,
    /// so the fitting size came back as "the centre column's minimum plus whatever the inspector
    /// was last dragged to". `NavigationSplitView` took that for the detail column's MINIMUM, and
    /// since it will not shrink its sidebar to satisfy one, the whole split view was laid out 121
    /// points wider than the window and centred in it: the sidebar's rows were clipped off their
    /// leading edge and the inspector's Create Pull Request button off the trailing one, at the
    /// window's own minimum size. Measured on this branch at 1000x700.
    ///
    /// The honest minimum is the sum of the panes that are ON SCREEN, which is not a constant: a
    /// collapsed inspector occupies nothing, so reporting its 281 points anyway is what held the
    /// window 281 points wider than it needed to be while two panes were showing. Same source as
    /// the window's own minimum, so the two cannot drift. See `WindowWidths`.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsViewController: DetailSplitViewController,
        context: Context
    ) -> CGSize? {
        let minimum = BloomApp.widths.detailHalf(withInspector: isInspectorPresented)
        return CGSize(
            width: max(proposal.width ?? minimum, minimum),
            height: proposal.height ?? 0
        )
    }

    func updateNSViewController(_ controller: DetailSplitViewController, context: Context) {
        controller.onInspectorPresentationChanged = { [weak app] presented in
            app?.isInspectorVisible = presented
        }
        controller.update(
            isInspectorPresented: isInspectorPresented,
            animated: animated,
            // What the detail column is showing, so the controller can tell a pane swap from an
            // inspector toggle. `detail` is an `AnyView` and answers nothing about identity, which
            // is why the selection is handed over beside it rather than derived from it.
            content: app.selection
        )
    }

    /// A hosting controller starts a new SwiftUI environment, so anything the panes read from above
    /// has to be handed back in. The model is the only thing either of them takes: appearance,
    /// reduce motion, control state and the rest arrive from AppKit on their own.
    private var detail: AnyView {
        AnyView(DetailColumn().environment(app))
    }

    private var inspector: AnyView {
        AnyView(
            SelectedInspectorPane()
                .environment(app)
        )
    }
}

/// The inspector's stable hosting root. It resolves the selected model inside its own observed
/// body, so AppKit never has to replace the `NSHostingView.rootView` to point it elsewhere.
private struct SelectedInspectorPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            retainedWorkspaces
            selectionWithoutLocalWorkspace
        }
    }

    /// The same two-workspace cache as the centre column. An inspector has its own file list,
    /// selected path, diff rows and hosted editors, and rebuilding those around a different model
    /// cost about 60ms of every otherwise warm switch.
    @ViewBuilder
    private var retainedWorkspaces: some View {
        ForEach(app.retainedWorkspaceIDs, id: \.self) { id in
            if let model = app.existingModel(for: id) {
                let isActive = app.selection.workspaceID == id
                InspectorPane(model: model)
                    .allowsHitTesting(isActive)
                    .accessibilityHidden(!isActive)
                    .zIndex(isActive ? 1 : 0)
            }
        }
    }

    /// Home and archived records have no local workspace id. They keep the existing
    /// inspector behaviour in front of the dormant local cache.
    @ViewBuilder
    private var selectionWithoutLocalWorkspace: some View {
        if app.selection.workspaceID == nil {
            InspectorPane(model: app.selectedModel)
                .zIndex(2)
        }
    }
}
