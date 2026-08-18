import SwiftUI

@main
struct BatonApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(BatonAppDelegate.self) private var appDelegate

    init() {
        // A development affordance: `Baton --snapshot <dir>` draws the interface straight to PNG
        // and exits, so it can be looked at without a screen recording permission. It has to run
        // before any scene exists, which is why it lives in the initialiser.
        if Snapshot.isRequested { Snapshot.runAndExit() }
        if Snapshot.isWindowCaptureRequested { Snapshot.scheduleWindowCapture() }
    }

    var body: some Scene {
        // A single `Window` rather than a `WindowGroup`. Baton's whole model is one window
        // listing every workspace, and a WindowGroup opens an extra window every time a
        // `baton://` link arrives, which is the opposite of what a deep link should do.
        Window("Baton", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1_000, minHeight: 620)
                .handlesBatonURLs(using: model)
                // The delegate needs the state to shut it down on quit, and this is the first
                // moment both exist. Handing it over explicitly keeps the app free of a global.
                .onAppear { appDelegate.attach(model) }
        }
        // A normal titled window, not `.hiddenTitleBar`. Hiding the title bar was what left the
        // traffic lights floating on a bare strip with the sidebar starting underneath them. A
        // unified toolbar puts them back where AppKit expects, on the same row as the toolbar,
        // and the split view gets its sidebar toggle for free. The title itself stays hidden
        // because the toolbar already names the workspace and its branch.
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1_440, height: 900)
        .commands { BatonCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
