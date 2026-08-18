import AppKit
import SwiftUI

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
/// a change by invalidating layout, which produces another minimum and maximum size. Nothing here
/// reads a hosted view's ideal size. The thicknesses below are constants, and `sizingOptions` is
/// emptied so a hosting controller never pushes a `preferredContentSize` up into the split item
/// holding it. That is the whole reason this is safe where the platform inspector is not.
final class DetailSplitViewController: NSSplitViewController {
    private let detailHost: NSHostingController<AnyView>
    private let inspectorHost: NSHostingController<AnyView>
    private var inspectorItem: NSSplitViewItem!

    /// What the centre column refuses to go below. The inspector's ceiling is the other side of the
    /// same coin, and AppKit derives it rather than us: with both minimums declared a drag simply
    /// stops, where the SwiftUI version had to recompute a ceiling from a measured width on every
    /// layout to stop the split view squeezing the sidebar instead.
    private static let detailMinimum: CGFloat = 420
    private static let inspectorMinimum: CGFloat = 280
    private static let inspectorMaximum: CGFloat = 760

    init(detail: AnyView, inspector: AnyView) {
        detailHost = NSHostingController(rootView: detail)
        inspectorHost = NSHostingController(rootView: inspector)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not decoded from a nib") }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Emptied on both. See the note on the type: a size travelling from the hosted SwiftUI
        // view up into the split item is the first half of the loop that kills this window.
        detailHost.sizingOptions = []
        inspectorHost.sizingOptions = []

        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.minimumThickness = Self.detailMinimum
        // The centre column is the one that absorbs a window resize, which is what a low holding
        // priority means. Without it, widening the window widens the inspector.
        detailItem.holdingPriority = .init(NSLayoutConstraint.Priority.defaultLow.rawValue)
        detailItem.canCollapse = false

        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorHost)
        inspectorItem.minimumThickness = Self.inspectorMinimum
        inspectorItem.maximumThickness = Self.inspectorMaximum
        inspectorItem.canCollapse = true

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
        splitView.autosaveName = "bloom.detail.split"
    }

    func update(detail: AnyView, inspector: AnyView, isInspectorPresented: Bool, animated: Bool) {
        detailHost.rootView = detail
        inspectorHost.rootView = inspector

        let shouldCollapse = !isInspectorPresented
        guard inspectorItem.isCollapsed != shouldCollapse else { return }
        // The animated setter runs a layout pass on every frame of the transition, and layout churn
        // is the condition this window has crashed under, so Reduce Motion turns it off rather than
        // merely shortening it.
        if animated {
            inspectorItem.animator().isCollapsed = shouldCollapse
        } else {
            inspectorItem.isCollapsed = shouldCollapse
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
