import SwiftUI
import AppKit
import BloomCore

/// An interactive sign-in command shared by GitHub and agent settings.
/// Keeping the process in Bloom avoids the Automation permission needed to control Terminal.app.
/// The session owns the terminal so SwiftUI layout updates cannot restart the command.
@MainActor
@Observable
final class LoginTerminalSession {
    /// The command, for the header above the terminal. Never anything but a program name and its
    /// flags: no output of the process is ever read back into the app.
    let label: String

    @ObservationIgnored let terminal: BloomTerminalView
    private(set) var isRunning = true

    private let launch: TerminalLaunch
    private var hasStarted = false

    /// Nil when the program is not on this Mac at all, which is the one case that cannot be a
    /// terminal because there is nothing to run in it.
    init?(
        executable: String,
        arguments: [String],
        directory: String,
        onExit: @escaping @MainActor (TerminalExit) -> Void
    ) {
        guard let path = Shell.which(executable) else { return nil }

        var variables = Shell.environment()
        variables["TERM"] = "xterm-256color"
        variables["COLORTERM"] = "truecolor"
        variables["TERM_PROGRAM"] = "Bloom"
        if variables["LANG"] == nil { variables["LANG"] = "en_US.UTF-8" }

        label = ([executable] + arguments).joined(separator: " ")
        launch = TerminalLaunch(
            executable: path,
            execName: executable,
            arguments: arguments,
            environment: variables.map { "\($0.key)=\($0.value)" }.sorted(),
            // An empty folder avoids macOS asking about home-directory access in Bloom's name.
            directory: FileManager.default.fileExists(atPath: directory)
                ? directory
                : AgentScratchDirectory.current()
        )

        terminal = BloomTerminalView(frame: .zero)
        // Keep the output visible after exit so the sheet can offer retry or completion.
        terminal.onExit = { [weak self] exit in
            guard let self, self.isRunning else { return }
            self.isRunning = false
            onExit(exit)
        }
    }

    /// Idempotent, because the SwiftUI view that hosts it asks on every layout pass. Once is the
    /// only number of times a login may be started: a second login under the same sheet
    /// would be two processes fighting over one pty.
    func start() {
        guard !hasStarted, isRunning else { return }
        hasStarted = true
        terminal.start(launch)
    }

    /// Kills the child. Called when the sheet closes by any route, including the close cross, so
    /// nothing is orphaned.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        terminal.shutdown()
    }
}

/// The SwiftUI face of a login terminal. It owns nothing: the live view comes from the session.
struct LoginTerminal: NSViewRepresentable {
    let session: LoginTerminalSession

    @AppStorage(TerminalGhostty.defaultsKey) private var usesGhosttyTheme = true
    @AppStorage(TerminalTextSize.defaultsKey) private var fontSize = 0.0

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        host.attach(session.terminal)
        configure()
        session.start()
        return host
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        // Attached and started here as well as in `makeNSView`: Try again builds a second session,
        // and SwiftUI reuses the host view rather than making a new one, so this is the only call
        // the second command would ever get.
        nsView.attach(session.terminal)
        configure()
        session.start()
    }

    private func configure() {
        session.terminal.usesGhosttyTheme = usesGhosttyTheme
        session.terminal.fontSizeOverride = fontSize > 0 ? CGFloat(fontSize) : nil
    }
}
