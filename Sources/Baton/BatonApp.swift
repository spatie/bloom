import SwiftUI

@main
struct BatonApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(BatonAppDelegate.self) private var appDelegate

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
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1_440, height: 900)
        .commands { BatonCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
