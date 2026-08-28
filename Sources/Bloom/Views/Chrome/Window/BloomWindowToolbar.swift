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
/// The navigation pane toggle lives here beside the traffic lights. The inspector control is the
/// primary action after the native search item. Both use `WindowPaneToggle`, so their geometry and
/// interaction remain a matched pair.
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
    let toggleSidebar: @MainActor @Sendable () -> Void
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

        // The elastic middle of the bar, and the whole reason the search field sits at the
        // window's trailing edge rather than beside the name.
        //
        // `.searchable` contributes an `NSSearchToolbarItem` after everything written here, and an
        // `NSToolbar` packs its items from the leading edge with no gap unless something between
        // them can stretch. What usually stretches is AppKit's own title item, and `RootView`
        // takes that away with `.toolbar(removing: .title)` because the name is drawn here
        // instead, so removing the second title also removed the toolbar's only piece of slack.
        //
        // Measured in an offscreen window 1440 points wide, with the same 380 point accessory:
        // without this the field's capsule starts at x=416, eight points from the title's own and
        // a third of the way across the bar, which is what the owner was looking at; with it, at
        // x=727, hard against the pull request band. The band is beyond the toolbar rather than
        // in it, so the two do not compete for the edge: the field takes the toolbar's trailing
        // end, the band takes the window's. See `TitleBarStrip`.
        ToolbarSpacer(.flexible, placement: .navigation)

        if app.selectedModel != nil {
            ToolbarItem(placement: .primaryAction) {
                WindowPaneToggle(
                    edge: .trailing,
                    isVisible: app.isInspectorVisible
                ) {
                    app.isInspectorVisible.toggle()
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }

        // The worktree's menu is not here any more. It was a trailing toolbar item, pinned to the
        // window's own edge, which put it directly above the inspector's pull request strip: two
        // stacked rows in the top right corner, both describing the same workspace. The strip has
        // taken the top row, since it is the one with a state in it, and the menu moved one place
        // left to where the centre column ends. The pull request band stays in `TitleBarStrip`,
        // because it has to be as wide as the pane below it. The inspector button is a primary
        // toolbar action so AppKit places it directly after the native search field.
    }

}
