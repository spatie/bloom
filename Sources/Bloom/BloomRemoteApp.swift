import SwiftUI
import BloomCore

/// The verification app uses the shipping server views without constructing the desktop's
/// AppModel, opening its database or starting its local workspace lifecycle.
struct BloomRemoteApp: App {
    var body: some Scene {
        Window("Bloom Remote", id: ServerWindow.id) {
            ServerWindowView()
                .frame(minWidth: 850, minHeight: 600)
        }
        .defaultSize(width: 1_200, height: 800)
        .windowToolbarStyle(.unified(showsTitle: true))
    }
}
