import SwiftUI
import AppKit
import BloomCore

/// One command running in a real pseudo terminal, watched by whoever started it.
///
/// `gh auth login` is interactive. It asks which host, which protocol, and how you want to
/// authenticate, then prints a one-time code and waits for Return before it opens a browser. None
/// of that can be run silently in a subprocess and be useful, and a read-only log of the output
/// would strand the user at the first question. So it runs where they can answer it.
///
/// The session owns the terminal rather than the SwiftUI view doing, because the view is a value
/// that comes and goes with every layout pass and the pty must not. `stop` is what guarantees no
/// `gh auth login` is left waiting on a terminal nobody can see any more.
@MainActor
@Observable
final class GitHubLoginSession {
    /// The command, for the header above the terminal. Never anything but a program name and its
    /// flags: no output of the process is ever read back into the app.
    let label: String

    @ObservationIgnored let terminal: BloomTerminalView
    private(set) var isRunning = true

    private let launch: TerminalLaunch
    private var hasStarted = false

    /// Nil when the program is not on this Mac at all, which is the one case that cannot be a
    /// terminal because there is nothing to run in it.
    init?(executable: String, arguments: [String], directory: String, onExit: @escaping @MainActor (Int32?) -> Void) {
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
            directory: FileManager.default.fileExists(atPath: directory)
                ? directory
                : FileManager.default.homeDirectoryForCurrentUser.path
        )

        terminal = BloomTerminalView(frame: .zero)
        // A Return after this exits belongs to the sheet, which is already checking the result. A
        // second `gh auth login` started under it is not a recovery.
        terminal.restartsOnReturn = false
        terminal.onExit = { [weak self] code in
            self?.isRunning = false
            onExit(code)
        }
    }

    /// Idempotent, because the SwiftUI view that hosts it asks on every layout pass. Once is the
    /// only number of times a login may be started: a second `gh auth login` under the same sheet
    /// would be two processes fighting over one pty.
    func start() {
        guard !hasStarted else { return }
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
struct GitHubLoginTerminal: NSViewRepresentable {
    let session: GitHubLoginSession

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
