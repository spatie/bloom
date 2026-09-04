import AppKit
import SwiftUI
import BloomCore

/// The card, the dim behind it and the ground that takes a click outside it, drawn over the whole
/// window rather than inside one of its panes.
///
/// # The bug this is
///
/// All of it was a SwiftUI `.overlay` declared on the window's `NavigationSplitView`, and what it
/// covered was the centre column and nothing else. Three reports, one cause. The inspector down
/// the right hand side kept its full brightness, with a hard vertical edge where the dim stopped
/// and the branch band and the Create pull request button above it lit as if the panel were not
/// there. A click on any of that ground did not close the panel, because whatever catches the
/// click outside is the same rectangle as the dim and it did not reach. And the card was centred
/// on the pane rather than on the window, so in a wide window it sat visibly left of the middle.
///
/// So it is not an overlay any more. It is an `NSHostingView` added last to the window's frame
/// view, which is `contentView.superview` and the one place in this window that is above every
/// pane, the toolbar and the title bar accessory at once. `RootView`'s split view is half AppKit
/// (see `DetailSplitViewController`), so where a SwiftUI overlay ends up in that hierarchy is not
/// a thing reading the interface settles; a sibling of the content view is above all of it by
/// construction and cannot be layered under a pane by anything SwiftUI does later.
///
/// # What dims, and what does not
///
/// The title bar dims with the content. The panel is anchored a little below the top of the
/// window and the strip up there carries the branch, the pull request state, a button that opens
/// one, the window's name and three small controls: leaving that lit while everything under it
/// goes down is exactly what the screenshot showed and it read as half a window.
///
/// **The traffic lights are the one exception, in the paint and in the hit test alike.** A window
/// that cannot be closed, zoomed or minimised while a search card is up would be a worse bug than
/// the one this fixes, and a dimmed close button is a control saying it is unavailable when it is
/// not. They are cut out of the dim with an even-odd fill and out of the hit test by
/// `SearchPanelOverlayHost`, so a click there reaches AppKit exactly as it always did.
///
/// # What a click outside does
///
/// It closes the panel and it does nothing else. The press lands on this view and stops, so the
/// Create pull request button, the two pane toggles, the magnifying glass and every sidebar row
/// cannot fire on the click that dismisses. "The panel closed and a pull request was created" is a
/// worse bug than the panel staying open, and this is the line that keeps it from being possible.
///
/// The cost is one gesture: a press in the title bar while the panel is up dismisses rather than
/// starting a window drag, because the drag is a mouse-down and the dismissal takes it. The next
/// press drags the window normally, which is the same bargain every other click outside makes.
/// Nothing is swallowed while the panel is closed: the host hit tests to nothing at all then, so
/// the window under it behaves exactly as it did before this file existed.
struct SearchPanelWindowOverlay: View {
    let app: AppModel
    let panel: SearchPanelModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var geometry: SearchPanelWindowGeometry { .shared }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                if panel.isOpen {
                    dim(in: proxy.size)
                    card(inWindow: proxy.size.width)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(reduceMotion ? nil : Motion.pane, value: panel.isOpen)
        }
        // A hosting view starts a new SwiftUI environment, so the model has to be handed back in.
        // `TitleBarStrip` does the same, one accessory along, for the same reason.
        .environment(app)
    }

    /// The dim, with a hole where the traffic lights are.
    ///
    /// One `Path` filled even-odd rather than a rectangle with a mask on it: the hole and the
    /// ground are one shape, so there is no second view whose blend mode has to agree with the
    /// first, and the rounded end of the cut-out is a `cornerSize` rather than a `Capsule` that
    /// has to be positioned.
    private func dim(in size: CGSize) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            if let hole = geometry.trafficLightHole(inViewOfHeight: size.height) {
                path.addRoundedRect(
                    in: hole,
                    cornerSize: CGSize(width: hole.height / 2, height: hole.height / 2)
                )
            }
        }
        .fill(Color.black.opacity(SearchPanelLayout.dim), style: FillStyle(eoFill: true))
        // The click outside, taken here rather than by the window under it. See the head of this
        // file for what that is protecting.
        .contentShape(Rectangle())
        .onTapGesture { panel.close(app: app) }
        .accessibilityHidden(true)
        .transition(.opacity)
    }

    /// The card itself, centred on the window because that is what this view is the size of.
    ///
    /// The title bar's height is added to the inset so the card hangs where it always hung. The
    /// dim now starts at the very top of the window and the card must not travel up with it: it
    /// is measured from the top of the CONTENT, which is what `SearchPanelLayout.topInset` means.
    private func card(inWindow windowWidth: CGFloat) -> some View {
        SearchPanelView(
            app: app,
            panel: panel,
            width: SearchPanelLayout.width(inWindow: windowWidth)
        )
        .padding(.top, geometry.titleBarHeight + SearchPanelLayout.topInset)
        .transition(.opacity)
    }
}

/// Where the window's own chrome is, measured off the window rather than assumed.
///
/// Shared rather than passed, and for the reason `InspectorGeometry` next door is: Bloom is one
/// window, the hosting view that measures this is made before the view that reads it, and an
/// `NSHostingView`'s root view is a value that would have to be rebuilt to carry a new number.
/// Both properties move with the window, so both are republished whenever the overlay's frame
/// changes rather than read once.
@MainActor
@Observable
final class SearchPanelWindowGeometry {
    static let shared = SearchPanelWindowGeometry()

    private init() {}

    /// The union of the close, minimise and zoom buttons with a little air around it, in the
    /// overlay's own AppKit coordinates: origin at the bottom left, because that is the space the
    /// window's frame view is in and the space a hit test arrives in.
    ///
    /// Nil before there is a window, and on a window whose buttons are gone.
    private(set) var trafficLights: CGRect?

    /// How much of the window the title bar takes, so the card can be hung below it.
    private(set) var titleBarHeight: CGFloat = 0

    /// The same rectangle in SwiftUI's space, which is the flip of the above.
    ///
    /// The flip is done here rather than at the call site because the height it needs is the
    /// overlay's own, and the overlay is the only thing that has it.
    func trafficLightHole(inViewOfHeight height: CGFloat) -> CGRect? {
        guard let trafficLights else { return nil }
        return CGRect(
            x: trafficLights.minX,
            y: height - trafficLights.maxY,
            width: trafficLights.width,
            height: trafficLights.height
        )
    }

    func setTrafficLights(_ rect: CGRect?) {
        guard trafficLights != rect else { return }
        trafficLights = rect
    }

    func setTitleBarHeight(_ height: CGFloat) {
        guard titleBarHeight != height else { return }
        titleBarHeight = height
    }
}

/// The hosting view the overlay is drawn in, which exists for its hit test.
///
/// Two questions AppKit asks that SwiftUI has no way to answer from inside a view: whether a point
/// belongs to this overlay at all, and whether a press on it moves the window. Both are wrong by
/// default for a view that covers the whole window all the time.
final class SearchPanelOverlayHost: NSHostingView<SearchPanelWindowOverlay> {
    /// The air left around the three buttons, so the cut-out is a rounded slot they sit in rather
    /// than three rectangles traced tightly enough to catch a click on the edge of one.
    private static let trafficLightPadding: CGFloat = 6

    /// Nothing at all while the panel is closed.
    ///
    /// This view is installed once and left in the window, because taking it out and putting it
    /// back is a chance to land in the wrong place in the subview order. So it has to be honestly
    /// invisible to the pointer the rest of the time: without this, a permanently installed sheet
    /// of glass over the whole window would eat every click in the app.
    ///
    /// The traffic lights are the second nil, and the head of `SearchPanelWindowOverlay` says why.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard SearchPanelModel.shared.isOpen else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        if let lights = SearchPanelWindowGeometry.shared.trafficLights, lights.contains(local) {
            return nil
        }
        return super.hitTest(point)
    }

    /// A press on this dismisses the panel; it never drags the window.
    ///
    /// `NSView` answers this true for a view with nothing drawn in it, and over the title bar that
    /// would hand the whole gesture to the window's drag before the click ever reached the panel:
    /// the dim would sit there while the window moved under it. It only ever applies while the
    /// panel is open, because a closed panel hit tests to nothing and this is never asked.
    override var mouseDownCanMoveWindow: Bool { false }

    /// Whether the frame observer is already registered.
    ///
    /// Once, not once per move into a window. Deregistering and registering again would be the
    /// obvious way to write this and SwiftLint refuses it, rightly: `notification_center_detachment`
    /// exists because an object that removes itself outside `deinit` removes every observation
    /// something else registered for it too. Registering once and letting `deinit` do the taking
    /// off is the shape that has no such hazard.
    private var isWatchingFrame = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // No safe area at all. This view is a sibling of the content view rather than a descendant
        // of it, so the inset the window reports for its title bar is the one region this overlay
        // must NOT respect: it is the region it exists to cover. Left on, SwiftUI would push the
        // dim down to where the content view starts, which is the bug over again.
        safeAreaRegions = []
        guard window != nil else {
            SearchPanelWindowGeometry.shared.setTrafficLights(nil)
            return
        }
        if !isWatchingFrame {
            isWatchingFrame = true
            // The frame rather than the window: this view is pinned to the frame view by an
            // autoresizing mask, so it hears about a resize, a full screen and a zoom alike, and
            // it hears about them after the new size is in rather than during a layout pass of
            // its own.
            postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(frameChanged),
                name: NSView.frameDidChangeNotification,
                object: self
            )
        }
        publishGeometry()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func frameChanged() {
        publishGeometry()
    }

    /// The two numbers the overlay draws itself from, measured off the window.
    ///
    /// The buttons are converted into this view's coordinates rather than read as window
    /// coordinates, because this view is a sibling of the content view in the frame view and its
    /// origin is the window's bottom left only for as long as that stays true.
    private func publishGeometry() {
        let geometry = SearchPanelWindowGeometry.shared
        guard let window else {
            geometry.setTrafficLights(nil)
            return
        }
        // The same measurement `WindowChrome` takes to size the title bar accessory: what the
        // title bar leaves over is the difference between the window and its content layout.
        geometry.setTitleBarHeight(max(0, window.frame.height - window.contentLayoutRect.height))

        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .filter { !$0.isHidden }
        guard let first = buttons.first else {
            geometry.setTrafficLights(nil)
            return
        }
        let union = buttons.dropFirst().reduce(first.convert(first.bounds, to: self)) {
            $0.union($1.convert($1.bounds, to: self))
        }
        geometry.setTrafficLights(union.insetBy(dx: -Self.trafficLightPadding, dy: -Self.trafficLightPadding))
    }
}
