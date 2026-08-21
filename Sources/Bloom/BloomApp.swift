import SwiftUI
import BloomCore

@main
struct BloomApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(BloomAppDelegate.self) private var appDelegate

    init() {
        // First, before anything else in the process. Every `@AppStorage` binding in the app
        // resolves its key the moment the view holding it is created, and a binding that has
        // already answered from an empty domain would then WRITE that empty answer back, which
        // is how a migration that runs one step too late destroys the thing it came to save.
        LegacyDefaults.migrate()

        // A development affordance: `Bloom --snapshot <dir>` draws the interface straight to PNG
        // and exits, so it can be looked at without a screen recording permission. It has to run
        // before any scene exists, which is why it lives in the initialiser.
        if Snapshot.isRequested { Snapshot.runAndExit() }
        if Snapshot.isWindowCaptureRequested { Snapshot.scheduleWindowCapture() }
        Snapshot.scheduleURLIfRequested()
        Snapshot.scheduleRunningStateIfRequested()
        Snapshot.scheduleSetupLogExpansionIfRequested()

        // A development affordance too: `Bloom --frame-probe <out.json>` drags the sidebar divider
        // and records how long each frame actually took. See `FrameProbe`.
        if FrameProbe.isRequested { FrameProbe.schedule() }

        // And another: `Bloom --switch-probe <out.json>` times the path from clicking a workspace
        // to seeing it. See `SwitchProbe`.
        if SwitchProbe.isRequested { SwitchProbe.schedule() }

        // And a last one: `Bloom --menu-probe <out.png>` opens one of the centre pane's split
        // submenus and photographs it, which nothing else can. Debug builds only. See `MenuProbe`.
        #if DEBUG
        if MenuProbe.isRequested { MenuProbe.schedule() }
        #endif
    }

    /// The narrowest the window may be dragged.
    ///
    /// Derived rather than a literal. It used to be a flat 1000, which was chosen before the
    /// centre column and the inspector became an `NSSplitViewController` with real minimum
    /// thicknesses. Those minimums do not negotiate: at 1000 the split view needed 121 points more
    /// than it was given and simply overflowed, so a window dragged to its own minimum clipped the
    /// sidebar's rows off their leading edge and the inspector's Create Pull Request button off
    /// the trailing one. `NavigationSplitView` does not shrink its sidebar to make room either, so
    /// the sidebar's MAXIMUM is what the rest has to be added to.
    private static let minimumWindowWidth =
        Self.sidebarMaximumWidth + DetailSplitViewController.minimumWidth + 1

    /// What the sidebar column may be dragged out to. Shared with `RootView`, which declares it on
    /// the column, so the window minimum above can never fall out of step with it.
    static let sidebarMaximumWidth: CGFloat = 420

    var body: some Scene {
        // A single `Window` rather than a `WindowGroup`. Bloom's whole model is one window
        // listing every workspace, and a WindowGroup opens an extra window every time a
        // `bloom://` link arrives, which is the opposite of what a deep link should do.
        Window("Bloom", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: Self.minimumWindowWidth, minHeight: 620)
                .handlesBloomURLs(using: model)
                // What the rest of the OS is told: the App Nap assertion and the dock badge,
                // the worktree behind the title bar, and the optional menu bar item. All three
                // follow the same state, and none of it is any feature view's business.
                .reportsAgentActivity(model)
                // The window's one heartbeat, for as long as an agent is working and the window
                // is the front one. Here rather than in either of the views that move, because
                // there are two of them and they have to be on the same clock. See `BusyPulse`.
                .runsBusyPulse(model)
                .showsWorktreeInTitleBar(model)
                .showsAgentsInMenuBar(model)
                // The title bar is painted in Bloom's chrome rather than in the system's window
                // material, so the strip across the top belongs to the same window as everything
                // under it. See `WindowChrome`.
                .paintsTitleBar(model)
                // The delegate needs the state to shut it down on quit, and this is the first
                // moment both exist. Handing it over explicitly keeps the app free of a global.
                .onAppear { appDelegate.attach(model) }
        }
        // A normal titled window, not `.hiddenTitleBar`. Hiding the title bar was what left the
        // traffic lights floating on a bare strip with the sidebar starting underneath them. A
        // unified toolbar puts them back where AppKit expects, on the same row as the toolbar,
        // and the split view gets its sidebar toggle for free.
        //
        // The title is shown, where it used to be hidden because the toolbar named the workspace
        // itself. A hidden title also hides the proxy icon, and with it the two things every
        // document window on the Mac can do: drag the folder out of the title bar, and
        // Command-click the title for the path above it. Bloom's workspaces are folders, so that
        // is worth more than a second copy of the name. The chip that used to sit beside it gave
        // the name up in return, then the project, then its last three items to the workspace's
        // own row in the sidebar, and the title bar is the window's again. See `TitleBarStrip`.
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1_440, height: 900)
        .commands {
            BloomCommands(model: model)
            // Attached to the MAIN window rather than to the project settings window group below,
            // because SwiftUI only realizes a scene's commands while one of that scene's own
            // windows is key, and an item that opens a window is no use only once it is open.
            RepoSettingsCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        // One window per project, opened from the gear on its sidebar header. See the scene.
        RepoSettingsWindow(model: model)
    }
}
