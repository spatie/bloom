import AppKit
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

/// A pane: an `NSHostingView` wrapped in a view controller so a split item can hold it.
///
/// Deliberately not an `NSHostingController`. That type exists to carry SwiftUI's measured size out
/// into AppKit through `sizingOptions` and `preferredContentSize`, and a split child controller
/// reading a measured size back into its item's thickness is the loop that kills this window. A
/// plain controller around an `NSHostingView` has no such channel at all: the pane fills whatever
/// the split view gives it, and nothing SwiftUI measures ever travels back the other way.
final class PaneViewController: NSViewController {
    private let host: MeasuredHostingView

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
        view = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        // No size travels out of SwiftUI. An `NSHostingView` publishes its content's ideal size as
        // an intrinsic content size, and the split view's autolayout then refuses to make the pane
        // any narrower than that. Measured on this branch: the inspector pane published 622 and the
        // centre column 519, so the split view stopped shrinking at 801 and overflowed a 702 point
        // container, hanging the inspector's trailing edge and its Create Pull Request button off
        // the side of the window at the window's own minimum size. `minimumThickness` on the two
        // items is the real floor and it is a required constraint, so nothing is lost by silencing
        // this one.
        host.sizingOptions = []
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
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

    /// What the centre column refuses to go below. The inspector's ceiling is the other side of the
    /// same coin, and AppKit derives it rather than us: with both minimums declared a drag simply
    /// stops, where the SwiftUI version had to recompute a ceiling from a measured width on every
    /// layout to stop the split view squeezing the sidebar instead.
    static let detailMinimum: CGFloat = 420
    static let inspectorMinimum: CGFloat = 280
    private static let inspectorMaximum: CGFloat = 760

    /// The narrowest the detail half of the window can be drawn, divider included.
    ///
    /// Public because the window's own minimum has to be built out of it. These are hard AppKit
    /// constraints: below this the split view stops laying out and starts clipping, and nothing
    /// above it in SwiftUI negotiates the difference away.
    static var minimumWidth: CGFloat { detailMinimum + inspectorMinimum + 1 }

    private static let autosaveName = "bloom.detail.split"

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

        // Replaces the `@AppStorage("inspector.width")` the SwiftUI version kept by hand.
        splitView.autosaveName = Self.autosaveName

        watchInspectorWidth()
    }

    /// Tells the title bar how wide the inspector currently is.
    ///
    /// The pull request strip sits above this pane now rather than inside it, and a band that does
    /// not end where the pane ends reads as a misalignment rather than as a heading.
    ///
    /// Two sources, because neither covers the other. A divider drag and a window resize move the
    /// pane's frame and post a notification for it; collapsing the pane does not, since a collapsed
    /// item here keeps the frame it had and is simply not drawn, so that half is published from
    /// `update` where the collapse is asked for. `viewDidLayout` was the first attempt at a single
    /// source and it is neither: it fired three times during launch and never again.
    private func watchInspectorWidth() {
        inspectorHost.view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneFrameChanged),
            name: NSView.frameDidChangeNotification,
            object: inspectorHost.view
        )
    }

    /// A drag or a resize. Never a slide: the pane is where it is, and the title bar should follow
    /// it this frame rather than a quarter of a second from now.
    @objc private func paneFrameChanged() {
        publishInspectorWidth(collapsed: inspectorItem.isCollapsed, sliding: false)
    }

    /// `collapsed` is passed in rather than read back off the item, because the animated setter
    /// below is told where the pane is going and "where is it now" is a question with two
    /// defensible answers while it is on its way there.
    private func publishInspectorWidth(collapsed: Bool, sliding: Bool) {
        let width = collapsed ? 0 : inspectorHost.view.frame.width
        InspectorGeometry.shared.setInspectorWidth(width, sliding: sliding)
    }

    func update(detail: AnyView, inspector: AnyView, isInspectorPresented: Bool, animated: Bool) {
        detailHost.rootView = detail
        inspectorHost.rootView = inspector

        let shouldCollapse = !isInspectorPresented
        guard inspectorItem.isCollapsed != shouldCollapse else { return }
        // The animated setter runs a layout pass on every frame of the transition, and layout churn
        // is the condition this window has crashed under, so Reduce Motion turns it off rather than
        // merely shortening it.
        guard animated else {
            inspectorItem.isCollapsed = shouldCollapse
            publishInspectorWidth(collapsed: shouldCollapse, sliding: false)
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
    /// The honest minimum is the sum of the two panes' minimum thicknesses, which is a constant.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsViewController: DetailSplitViewController,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: max(proposal.width ?? DetailSplitViewController.minimumWidth,
                       DetailSplitViewController.minimumWidth),
            height: proposal.height ?? 0
        )
    }

    func updateNSViewController(_ controller: DetailSplitViewController, context: Context) {
        controller.update(
            detail: detail,
            inspector: inspector,
            isInspectorPresented: isInspectorPresented,
            animated: animated
        )
    }

    /// A hosting controller starts a new SwiftUI environment, so anything the panes read from above
    /// has to be handed back in. The model is the only thing either of them takes: appearance,
    /// reduce motion, control state and the rest arrive from AppKit on their own.
    private var detail: AnyView {
        AnyView(DetailColumn().environment(app))
    }

    private var inspector: AnyView {
        AnyView(InspectorPane(model: app.selectedModel).environment(app))
    }
}
