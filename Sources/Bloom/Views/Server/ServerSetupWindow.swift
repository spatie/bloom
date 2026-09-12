import SwiftUI

/// Adding a server starts with an introduction, independently of the current connection.
struct ServerSetupWindow: Scene {
    static let id = "bloom-server-setup"
    let model: AppModel

    var body: some Scene {
        Window("Add Server", id: Self.id) {
            ServerSetupContent(app: model)
                .environment(model)
                .windowRole(.utility)
        }
        .windowResizability(.contentSize)
    }
}

private struct ServerSetupContent: View {
    let app: AppModel
    @State private var setup: ServerSetupModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    init(app: AppModel) {
        self.app = app
        _setup = State(initialValue: ServerSetupModel(server: app.remoteServer, resumeExisting: false))
    }

    var body: some View {
        ServerSetupView(model: setup, showAdvanced: {
            openWindow(id: ServerWindow.id)
            dismissWindow(id: ServerSetupWindow.id)
        }, windowID: ServerSetupWindow.id)
        .onAppear {
            setup = ServerSetupModel(server: app.remoteServer, resumeExisting: false)
        }
    }
}
