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

        // The stored appearance, applied while the process is still faceless. It used to be a
        // side effect of `SettingsView.init`, which made a dark preference's arrival at launch
        // depend on SwiftUI choosing to construct the Settings scene's content eagerly, an
        // implementation detail that owed nothing to the first window drawn.
        AppearancePreference.apply(UserDefaults.standard.string(forKey: "appearance") ?? "system")

        // A development affordance: `Bloom --snapshot <dir>` draws the interface straight to PNG
        // and exits, so it can be looked at without a screen recording permission. It has to run
        // before any scene exists, which is why it lives in the initialiser.
        if Snapshot.isRequested { Snapshot.runAndExit() }
        if Snapshot.isWindowCaptureRequested { Snapshot.scheduleWindowCapture() }
        if Snapshot.isGalleryCaptureRequested { Snapshot.scheduleGalleryCapture() }
        Snapshot.scheduleURLIfRequested()
        Snapshot.scheduleRunningStateIfRequested()
        Snapshot.scheduleSetupLogExpansionIfRequested()
        Snapshot.scheduleNoticeIfRequested()
        Snapshot.scheduleTerminalWorkspaceIfRequested()

        // A development affordance too: `Bloom --frame-probe <out.json>` drags the sidebar divider
        // and records how long each frame actually took. See `FrameProbe`.
        if FrameProbe.isRequested { FrameProbe.schedule() }

        // And another: `Bloom --switch-probe <out.json>` times the path from clicking a workspace
        // to seeing it. See `SwitchProbe`.
        if SwitchProbe.isRequested { SwitchProbe.schedule() }

        // And its sibling one level in: `Bloom --tab-probe <out.json>` times the path from picking
        // a tab in the centre column to seeing it. See `TabProbe`.
        if TabProbe.isRequested { TabProbe.schedule() }

        // And the one that answers "the chat does not scroll smoothly": `Bloom --scroll-probe
        // <out.json>` walks a long transcript top to bottom and records what each frame cost.
        // See `ScrollProbe`.
        if ScrollProbe.isRequested { ScrollProbe.schedule() }

        // And the one that answers "resizing is not smooth when there is a chat, a browser and a
        // change list on screen at once": `Bloom --resize-probe <out.json>` puts all three up and
        // then drags the window's own edge. `FrameProbe --probe-gesture window` measures the same
        // gesture with whatever happened to be showing; this one measures the arrangement the
        // complaint is about. See `ResizeProbe`.
        if ResizeProbe.isRequested { ResizeProbe.schedule() }

        // And the one that measures the app being USED rather than a gesture somebody made to it:
        // `Bloom --stream-probe <out.json>` types into the composer and then streams a turn into
        // the transcript, and reports what each keystroke and each delta cost the window. See
        // `StreamProbe`.
        if StreamProbe.isRequested { StreamProbe.schedule() }

        // And the one that asks whether a gesture DID WHAT IT SAID rather than what it cost:
        // `Bloom --jump-probe <out.json>` asks for the live end from several starting positions
        // and reports how far short of it the view came to rest. See `JumpProbe`.
        if JumpProbe.isRequested { JumpProbe.schedule() }

        // And the one that answers "the battery menu says Bloom is using significant energy":
        // `Bloom --idle-probe <out.json> --idle-worktrees <list>` runs the diff stat pass the six
        // second loop runs and reports what it cost in process time and in subprocesses. It is the
        // only one of the family that measures the case where nothing is happening. See `IdleProbe`.
        if IdleProbe.isRequested { IdleProbe.schedule() }

        // And two last ones. `Bloom --menu-probe <out.png>` opens one of the centre pane's split
        // submenus and photographs it, which nothing else can; `Bloom --menu-action <title>`
        // performs a real item of a real menu and reports the windows either side of it, which is
        // the only way to answer "clicking that did nothing". Debug builds only. See `MenuProbe`
        // and `MenuActionProbe`.
        #if DEBUG
        if MenuProbe.isRequested { MenuProbe.schedule() }
        if MenuActionProbe.isRequested { MenuActionProbe.schedule() }
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

    /// The main window's scene id. Named rather than repeated, because the create window brings
    /// it forward after a workspace is made and a second literal is how those two stop matching.
    static let mainWindowID = "main"

    /// What the sidebar column may be dragged out to. Shared with `RootView`, which declares it on
    /// the column, so the window minimum above can never fall out of step with it.
    static let sidebarMaximumWidth: CGFloat = 420

    var body: some Scene {
        // A single `Window` rather than a `WindowGroup`. Bloom's whole model is one window
        // listing every workspace, and a WindowGroup opens an extra window every time a
        // `bloom://` link arrives, which is the opposite of what a deep link should do.
        Window("Bloom", id: Self.mainWindowID) {
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
                .showsWorkspaceInTitleBar(model)
                .showsAgentsInMenuBar(model)
                // The title bar is painted in Bloom's chrome rather than in the system's window
                // material, so the strip across the top belongs to the same window as everything
                // under it. See `WindowChrome`.
                .paintsTitleBar()
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
            // One `Commands` body, and it is on the MAIN window: SwiftUI only realizes a scene's
            // commands while one of that scene's own windows is key, so the item that opens the
            // project settings window cannot live on that window's own scene or it would appear
            // only once the window was already open. It is a row of `BloomCommands`' File group
            // now, which is where `MenuBarCatalogue` says it is.
            BloomCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(model)
                // Cmd+W, which every window in the app lost when the standard Close was re-keyed.
                // Not Escape: this window is full of fields, and Escape in a field reverts the
                // edit. See `WindowRoles`.
                .windowRole(.utility)
        }

        // One window per project, opened from the gear on its sidebar header. See the scene.
        RepoSettingsWindow(model: model)

        // Where a workspace is started. A window rather than a sheet on the main window, so the
        // code being described can be read while the task is written. See the scene.
        CreateWorkspaceWindow(model: model)

        // Where a project is started, a window for the same reason and at the owner's asking. One
        // of these rather than one per project: it is not about a project yet. See the scene.
        StartProjectWindow(model: model)

        // The map of the seas workspaces have been named after, opened from the Window menu.
        // See the scene.
        OceansWindow(model: model)
    }
}
