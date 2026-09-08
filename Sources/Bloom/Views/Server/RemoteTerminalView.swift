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
        .task(id: model.selectedWorkspace?.id) {
            terminal = nil
            error = nil
            do { terminal = try await model.terminal(named: name) } catch { self.error = error.localizedDescription }
        }
    }
}

private struct RemoteTerminalHost: NSViewRepresentable {
    let terminal: BloomTerminalView
    @AppStorage(TerminalGhostty.defaultsKey) private var usesGhosttyTheme = true
    @AppStorage(TerminalTextSize.defaultsKey) private var fontSize = 0.0

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        host.attach(terminal)
        return host
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        terminal.usesGhosttyTheme = usesGhosttyTheme
        terminal.fontSizeOverride = fontSize > 0 ? CGFloat(fontSize) : nil
        host.attach(terminal)
    }
}
