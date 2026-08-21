import AppKit
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
@MainActor
@Observable
final class InspectorGeometry {
    static let shared = InspectorGeometry()

    /// The inspector pane's width in points, zero while it is collapsed.
    private(set) var width: CGFloat = 0

    /// Called when it moves. Not observation: the reader is an `NSView` frame.
    @ObservationIgnored var onChange: (() -> Void)?

    private init() {}

    /// Below this the pane is closed or mid animation, and the strip should not be drawn.
    var isVisible: Bool { width > 1 }

    func setInspectorWidth(_ value: CGFloat) {
        guard abs(width - value) > 0.5 else { return }
        width = value
        onChange?()
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
struct TitleBarStrip: View {
    let app: AppModel

    /// The title bar's own height, measured off the window before this view was put in it.
    let height: CGFloat

    private var inspector: InspectorGeometry { .shared }

    var body: some View {
        Group {
            if let model = app.selectedModel, inspector.isVisible {
                PullRequestBar(model: model)
                    // As wide as the pane below it, so the band ends where the pane does and the
                    // split divider runs out of the bottom of it.
                    .frame(width: inspector.width, height: height)
                    .background { ground(for: model) }
            }
        }
        .frame(height: height)
        // A separate SwiftUI root: the window's environment does not reach a title bar accessory,
        // so the model is handed in rather than inherited.
        .environment(app)
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

    init(app: AppModel, height: CGFloat) {
        self.height = height
        super.init(nibName: nil, bundle: nil)

        let host = NSHostingView(rootView: TitleBarStrip(app: app, height: height))

        // No size travels out of SwiftUI here, for the same reason it does not in the split view's
        // panes: the accessory container sets this view's frame, and an intrinsic content size only
        // gives autolayout a second opinion about it.
        host.sizingOptions = []
        view = host
        layoutAttribute = .trailing
        // What the accessory keeps while the title bar is in its full screen state. Without it the
        // strip is the one thing in the title bar that can be given no height at all.
        fullScreenMinHeight = height

        InspectorGeometry.shared.onChange = { [weak self] in self?.resize() }
        resize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not decoded from a nib") }

    /// One point rather than zero when there is nothing to show, so the accessory is never a view
    /// of no size at all in the title bar's layout. On Home and on Search that is what it is.
    private func resize() {
        let width = max(InspectorGeometry.shared.width, 1)
        guard abs(view.frame.width - width) > 0.5 else { return }
        view.setFrameSize(NSSize(width: width, height: height))
        view.superview?.needsLayout = true
    }
}
