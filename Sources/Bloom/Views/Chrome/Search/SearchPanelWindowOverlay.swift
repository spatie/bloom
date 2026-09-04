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
/// **The traffic lights are cut out of the HIT TEST and of nothing else, and the two halves of
/// that are a decision each.** The window has to stay closable, zoomable and minimisable while a
/// card is up, so `SearchPanelOverlayHost` answers nothing over them and the click reaches AppKit
/// exactly as it always did. But they are painted over like everything else, because they are part
/// of the window the panel is in front of. They were cut out of the paint as well for two
/// versions, on the argument that a dimmed close button is a control claiming to be unavailable
/// when it is not; the owner looked at that twice and did not want it, and he is right that the
/// exception was louder than the thing it was protecting. The hole was the brightest object in an
/// otherwise dimmed window, on the one corner nobody was looking at.
///
/// What that costs, said plainly because it is a real cost. AppKit draws the symbols in those
/// buttons on hover, and the scrim is over the top, so the cross and the two dashes come up dimmed
/// with everything else. Nothing is disturbed, because the buttons never learn about the scrim:
/// their tracking area still gets the mouse, since the hit test passes through, and they still
/// draw and still fire. A coloured button under a 22 to 40 per cent scrim also reads a little like
/// an inactive window's grey, which is the one honest objection to this and is the owner's to
/// weigh rather than mine.
///
/// **How far the window goes down is `Palette.panelScrim`, and it is two numbers.** A black scrim
/// has far less to take out of Bloom's dark ramp than out of its light one, so one opacity read as
/// a grey page in light and as nothing at all in dark. `SearchPanelLayout.dimDark` carries the
/// measurement and the argument.
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
                    dim
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

    /// The dim, over the whole window and with nothing cut out of it.
    ///
    /// It carried a hole where the traffic lights are for two versions. The hole is gone from the
    /// paint and kept in the hit test, and the head of this file says why the two are not the same
    /// question.
    private var dim: some View {
        Rectangle()
            .fill(Palette.panelScrim)
            // The click outside, taken here rather than by the window under it. See the head of
            // this file for what that is protecting.
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
///
/// **Every number here is measured against the window's frame view, and that is the whole point.**
/// The first version of this asked the window for `contentLayoutRect` and asked the buttons to
/// convert themselves into the overlay's own coordinates, and both answers were wrong in the
/// picture. `contentLayoutRect` is what the title bar leaves over AFTER its accessories, and Bloom
/// puts a 52 point band up there, so the title bar measured 152 and the card hung a hundred points
/// too low. The buttons converted into a hosting view whose flippedness is SwiftUI's business, so
/// the cut-out for the traffic lights came out mirrored and appeared as a bright slot in the bottom
/// left of the sidebar. The frame view is neither: it is a plain unflipped `NSView` whose bounds
/// are the window's frame, it is the superview a hit test arrives in, and it is the space the
/// overlay itself is pinned to.
@MainActor
@Observable
final class SearchPanelWindowGeometry {
    static let shared = SearchPanelWindowGeometry()

    private init() {}

    /// The union of the close, minimise and zoom buttons with a little air around it, in the frame
    /// view's coordinates: unflipped, origin at the window's bottom left. That is the space
    /// `hitTest` is asked in, which is why it is the one held.
    ///
    /// Nil before there is a window, and on a window whose buttons are gone.
    private(set) var trafficLights: CGRect?

    /// How tall the title bar is, so the card can be hung below it rather than against it.
    ///
    /// **`WindowChrome` is the one writer, and that is the whole point.** Two other ways of asking
    /// were tried in the picture and both were wrong. `contentLayoutRect` is what the title bar
    /// leaves over AFTER its accessories, and Bloom puts a 52 point band up there, so it answered
    /// 152 and the card hung a hundred points too low. The content view's own frame answered zero,
    /// because a window with a transparent title bar gives its content the whole frame, and the
    /// card then sat two points under the toolbar. The only honest measurement in this app is the
    /// one `WindowChrome` already takes, before any accessory is in the bar, and it is the number
    /// the strip itself is built at.
    private(set) var titleBarHeight: CGFloat = 0

    /// Called by `WindowChrome` with the height it measured for the title bar strip.
    func setTitleBarHeight(_ height: CGFloat) {
        guard titleBarHeight != height else { return }
        titleBarHeight = height
    }

    /// Called by the overlay whenever the window moves under it.
    func setChrome(trafficLights: CGRect?) {
        guard self.trafficLights != trafficLights else { return }
        self.trafficLights = trafficLights
    }
}

/// The hosting view the overlay is drawn in, which exists for its hit test.
///
/// Two questions AppKit asks that SwiftUI has no way to answer from inside a view: whether a point
/// belongs to this overlay at all, and whether a press on it moves the window. Both are wrong by
/// default for a view that covers the whole window all the time.
final class SearchPanelOverlayHost: NSHostingView<SearchPanelWindowOverlay> {
    /// The air left around the three buttons in the HIT TEST hole, so a click at the edge of a
    /// circle still reaches it rather than landing on the overlay and closing the panel.
    ///
    /// It used to size a hole in the paint as well and was tuned against a capture for that: six
    /// points read as a bright pill drawn on the corner, three as a halo. The paint has no hole
    /// any more, so the number is only ever asked what the pointer can reach, and three points of
    /// slop around a 14 point circle is generous for that and invisible either way.
    ///
    /// **How to measure a hole in a capture, kept because it was hard won and the next person to
    /// draw one will want it.** The obvious detector is wrong: asking which pixels differ from the
    /// dim selects every antialiased glyph in a title bar that is dithered rather than flat. A hole
    /// is an absence, so the question is which pixels are the ground with NO scrim over them.
    /// Count the ones within about 6 of `#F1F5F6` in light or 3 of `#0E202D` in dark, inside the
    /// top left 240 by 120 points, and take the bounding box. Nothing else in that corner sits on
    /// the undimmed ground and antialiasing never lands on it in bulk, so it needs no tuning: it
    /// read 72 by 26 at six points of padding and 66 by 20 at three, on every capture, first time.
    private static let trafficLightPadding: CGFloat = 3

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
        // `point` arrives in the SUPERVIEW's coordinates and the buttons were measured in the
        // superview's coordinates, so they are compared there and nothing is converted. Converting
        // into this view would be the mistake: a hosting view is flipped, so the y would come out
        // upside down, which is exactly how the cut-out ended up in the bottom of the sidebar the
        // first time.
        if let lights = SearchPanelWindowGeometry.shared.trafficLights, lights.contains(point) {
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

    /// Whether the window observers are already registered.
    ///
    /// Once, not once per move into a window. Deregistering and registering again would be the
    /// obvious way to write this and SwiftLint refuses it, rightly: `notification_center_detachment`
    /// exists because an object that removes itself outside `deinit` removes every observation
    /// something else registered for it too.
    private var isWatchingWindow = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // No safe area at all. This view is a sibling of the content view rather than a descendant
        // of it, so the inset the window reports for its title bar is the one region this overlay
        // must NOT respect: it is the region it exists to cover.
        safeAreaRegions = []
        guard let window else {
            SearchPanelWindowGeometry.shared.setChrome(trafficLights: nil)
            return
        }
        if !isWatchingWindow {
            isWatchingWindow = true
            let centre = NotificationCenter.default
            for name in [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
            ] {
                centre.addObserver(
                    self, selector: #selector(windowGeometryChanged), name: name, object: window
                )
            }
            if let frame = superview {
                frame.postsFrameChangedNotifications = true
                centre.addObserver(
                    self,
                    selector: #selector(windowGeometryChanged),
                    name: NSView.frameDidChangeNotification,
                    object: frame
                )
            }
        }
        windowGeometryChanged()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowGeometryChanged() {
        matchTheFrameView()
        publishGeometry()
    }

    /// Keeps this view exactly the size of the window.
    ///
    /// **An autoresizing mask is not enough, and that was measured rather than assumed.** The
    /// window's frame view is AppKit's own and it lays out the subviews it knows about; a view
    /// somebody else added is not resized by it. The first capture of this branch proved it: the
    /// overlay was installed at the window's restored height, the capture then set a different
    /// content size, and the overlay kept the old one. Because the frame view is unflipped the
    /// overlay stayed anchored to the BOTTOM and hung a hundred points off the top, which is what
    /// put the traffic light cut-out down in the sidebar. The mask stays on because it is right
    /// whenever AppKit does run it; this is what makes it true when AppKit does not.
    private func matchTheFrameView() {
        guard let frame = superview, self.frame != frame.bounds else { return }
        self.frame = frame.bounds
    }

    /// Where the window buttons are, measured off the frame view. The title bar's height is the
    /// other number the overlay needs and it is `WindowChrome`'s, for the reason on the property.
    private func publishGeometry() {
        let geometry = SearchPanelWindowGeometry.shared
        guard let window, let frame = superview else {
            geometry.setChrome(trafficLights: nil)
            return
        }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .filter { !$0.isHidden }
        var lights: CGRect?
        if let first = buttons.first {
            let union = buttons.dropFirst().reduce(first.convert(first.bounds, to: frame)) {
                $0.union($1.convert($1.bounds, to: frame))
            }
            lights = union.insetBy(dx: -Self.trafficLightPadding, dy: -Self.trafficLightPadding)
        }
        geometry.setChrome(trafficLights: lights)
    }
}
