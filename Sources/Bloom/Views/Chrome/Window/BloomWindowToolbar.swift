import SwiftUI
import BloomCore

/// The window toolbar.
///
/// A `ToolbarContent` type rather than a `@ToolbarContentBuilder` property on `RootView`, so the
/// toolbar takes the model as an input rather than reaching for it as ambient environment.
///
/// It is attached to the DETAIL column, never to the `NavigationSplitView`. See `RootView` for the
/// crash that taught us the difference.
///
/// The two pane toggles live here as one matched pair. The navigation control follows the traffic
/// lights and the inspector control takes the trailing action position. They use the same quiet
/// icon treatment, so the window reads as navigation, content and inspection rather than as one
/// native toolbar button and one unrelated control in the tab strip.
///
/// **Nor is there a `+` any more.** It appeared only while the sidebar was folded away, on the
/// argument that nothing else in the window starts work in that state. What the owner saw was a
/// split button with a bare caret beside the traffic lights, which is a control the eye has to
/// stop on before it can be dismissed. Command N and Option Command N still start a workspace and
/// a project from anywhere, in either state, so nothing is only reachable from a pointer that has
/// folded the pane away.
///
/// And the window's title, which is here because AppKit no longer draws it: a title of our own is
/// what lets a double click on the NAME start a rename without stealing the double click on the
/// BAR that Desktop & Dock has already spent. See `WindowTitleControl`.
///
/// There is no Refresh Changes either. The changed file list polls every six seconds and redraws
/// itself, so the command could only ever do what had already happened, and a control that does
/// nothing teaches the user that the list is not to be trusted.
struct BloomWindowToolbar: ToolbarContent {
    let app: AppModel
    let isSidebarVisible: Bool
    let isInspectorVisible: Bool
    let toggleSidebar: @MainActor @Sendable () -> Void
    let toggleInspector: @MainActor @Sendable () -> Void
    let startFreshAskConversation: () -> Void

    var body: some ToolbarContent {
        // NavigationSplitView's default sidebar item offers a label-style context menu on macOS
        // 26. Bloom always shows this control as an icon, so a choice between "Icon and Text" and
        // "Icon Only" has no useful effect. RootView removes that default item and this image-only
        // button keeps the native placement and action without advertising a setting Bloom ignores.
        ToolbarItem(placement: .navigation) {
            WindowPaneToggle(
                edge: .leading,
                isVisible: isSidebarVisible,
                action: toggleSidebar
            )
        }
        .sharedBackgroundVisibility(.hidden)

        // The window's title, drawn by us rather than by AppKit.
        //
        // A toolbar item and not a title bar accessory, which is what the strip at the other end
        // is. A leading accessory is placed "adjacent and to the right of the close/minimize/
        // maximize buttons", per `NSTitlebarAccessoryViewController.h`, so it would sit BEFORE the
        // `+` above rather than after it, and an accessory is sized from its view's frame rather
        // than from its content, so the width of a name would have to be measured by hand and
        // measured again on every keystroke while it is being edited. A toolbar item is laid out
        // in the order written and sizes itself, which is both of those for free.
        //
        // Second in the group, so the `+` keeps the leading edge on the one screen it appears on.
        // See `WindowTitleControl` for why the title is a view of ours at all.
        ToolbarItem(placement: .navigation) {
            WindowTitleControl(app: app)
        }
        // No plate behind the name. AppKit gives every toolbar item a shared background, which
        // put a glass capsule around the window's title; next to the bare `Home`/`Ask Bloom` rows
        // and the plain search field it read as a control you could press, and the name is not
        // one. The switch is the one `WindowTitleControl`'s notes name: it turns the plate off
        // rather than dividing it, so the item still sits where it sat.
        .sharedBackgroundVisibility(.hidden)

        if app.selection == .ask, app.ask.session != nil {
            ToolbarItem(placement: .navigation) {
                Button(action: startFreshAskConversation) {
                    Image(systemName: "square.and.pencil")
                }
                .help("Start a new Ask Bloom conversation")
                .accessibilityLabel("Start a new Ask Bloom conversation")
            }
        }

        // The elastic middle leaves the native principal search field centred in the window.
        //
        ToolbarSpacer(.flexible, placement: .navigation)

        if app.selectedWorkspace != nil {
            ToolbarItem(placement: .primaryAction) {
                WindowPaneToggle(
                    edge: .trailing,
                    isVisible: isInspectorVisible,
                    action: toggleInspector
                )
            }
            .sharedBackgroundVisibility(.hidden)
        }

        // The worktree menu belongs to its row in the sidebar. The pull request header belongs to
        // the inspector. Keeping both out of this toolbar leaves its two ends as a matched pair.
    }

}
