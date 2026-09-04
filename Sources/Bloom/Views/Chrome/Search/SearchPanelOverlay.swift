import AppKit
import SwiftUI
import BloomCore

/// Puts the panel in the window, and rebuilds its list when the things it lists move.
///
/// **The panel is not drawn from here any more.** It used to be an `.overlay` on the window's
/// split view, which is why it dimmed the centre column and left the inspector, the title bar and
/// everything in them alone. It is an `NSHostingView` over the whole window now, installed once
/// and left in place, and `SearchPanelWindowOverlay` is where the whole of that decision is
/// written down. What is left here is the installation and the wiring, which need a view.
///
/// **The window is dimmed and it does not move.** Spotlight and Raycast float over the screen;
/// VS Code and Sublime pin their panel to the top of the window, and that is what this is, because
/// the panel acts on this window's contents. Dimmed rather than blurred: a blur costs a live
/// backdrop filter over the whole window for a card that is up for two seconds, and what the dim
/// has to say is only "this is in front".
struct SearchPanelOverlay: ViewModifier {
    let app: AppModel
    @Bindable var panel: SearchPanelModel

    @State private var window: NSWindow?
    @State private var host: SearchPanelOverlayHost?

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor(window: $window))
            .onChange(of: window, initial: true) { _, _ in install() }
            // Home's list must not take the keyboard off a field somebody is typing in, and this
            // is the flag it reads. The panel's field is a field in the window exactly as the
            // toolbar's was. See `HomeListKeyboard`.
            .onChange(of: panel.isOpen) { _, open in
                app.isSearchFieldFocused = open
                if open { raise() }
            }
            // The list is rebuilt when its inputs move rather than while drawing, which is the
            // same rule Home's `rebuild` keeps and for the same reason: it runs over every
            // workspace on the machine.
            .onChange(of: app.workspaces) { _, _ in panel.rebuild(app: app) }
            .onChange(of: app.repos) { _, _ in panel.rebuild(app: app) }
            .onChange(of: app.transcriptResults) { _, _ in panel.rebuild(app: app) }
            // The two halves of the running state, watched separately because they move
            // separately: a turn starting and a turn stopping to ask are different moments, and
            // both change what the resting list leads with.
            .onChange(of: app.runningWorkspaceIDs) { _, _ in panel.rebuild(app: app) }
            .onChange(of: app.waitingWorkspaceIDs) { _, _ in panel.rebuild(app: app) }
    }

    /// Adds the overlay to the window's frame view, above the content view and above the title
    /// bar, once.
    ///
    /// `contentView.superview` rather than the content view itself. The content view of a SwiftUI
    /// scene is a hosting view whose subviews SwiftUI owns and reorders; a sibling of it is
    /// nobody's to reorder, and it is also the only ground that reaches over the toolbar and the
    /// title bar accessory. The autoresizing mask is what keeps it the size of the window through
    /// a resize, a zoom and a full screen, and `SearchPanelOverlayHost` measures the traffic
    /// lights off each of those moves.
    private func install() {
        guard host == nil, let window, let frame = window.contentView?.superview else { return }
        let view = SearchPanelOverlayHost(
            rootView: SearchPanelWindowOverlay(app: app, panel: panel)
        )
        view.frame = frame.bounds
        view.autoresizingMask = [.width, .height]
        frame.addSubview(view, positioned: .above, relativeTo: nil)
        host = view
    }

    /// Puts it back on top when the panel opens.
    ///
    /// Not belt and braces. The frame view is AppKit's own and it adds views to it: a toolbar
    /// arriving, a title bar accessory being added or a full screen transition all touch that
    /// subview list, and any of them can end up above a view added before them. Asking once, on
    /// the one event that matters, costs nothing and cannot be got wrong later.
    private func raise() {
        guard let host, let frame = host.superview else { return }
        frame.addSubview(host, positioned: .above, relativeTo: nil)
    }
}

extension View {
    /// The panel, over this window.
    func searchPanel(app: AppModel) -> some View {
        modifier(SearchPanelOverlay(app: app, panel: SearchPanelModel.shared))
    }
}
