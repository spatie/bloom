import SwiftUI

struct RemoteTerminalView: View {
    @Bindable var model: ServerWindowModel
    var name = "main"
    @State private var terminal: BloomTerminalView?
    @State private var error: String?

    var body: some View {
        Group {
            if let terminal {
                RemoteTerminalHost(terminal: terminal)
            } else if let error {
                ContentUnavailableView("Cannot open terminal", systemImage: "terminal", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: (model.selectedWorkspace?.id.rawValue ?? "") + name + String(model.connectionGeneration)) {
            terminal = nil
            error = nil
            do {
                let loaded = try await model.terminal(named: name)
                if !Task.isCancelled { terminal = loaded }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

private struct RemoteTerminalHost: NSViewRepresentable {
    let terminal: BloomTerminalView

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        host.attach(terminal)
        terminal.updateTheme()
        return host
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        // The same call the local pane makes on every update, so a theme picked in Settings
        // reaches a server's shell exactly as it reaches one on this Mac.
        host.attach(terminal)
        terminal.updateTheme()
    }
}
