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
    convenience init?(
        executable: String,
        arguments: [String],
        directory: String,
        onExit: @escaping @MainActor (TerminalExit) -> Void
    ) {
        guard let path = Shell.which(executable) else { return nil }

        let variables = Shell.terminalEnvironment(inheriting: Shell.environment())

        let launch = TerminalLaunch(
            executable: path,
            execName: executable,
            arguments: arguments,
            environment: variables.map { "\($0.key)=\($0.value)" }.sorted(),
            // An empty folder avoids macOS asking about home-directory access in Bloom's name.
            directory: FileManager.default.fileExists(atPath: directory)
                ? directory
                : AgentScratchDirectory.current()
        )

        self.init(launch: launch, label: ([executable] + arguments).joined(separator: " "), onExit: onExit)
    }

    /// Remote sign-in supplies an SSH launch, but shares the same terminal lifetime as local login.
    init(launch: TerminalLaunch, label: String, onExit: @escaping @MainActor (TerminalExit) -> Void) {
        self.label = label
        self.launch = launch

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

/// The framed terminal every sign-in sheet shows: what is running along the top, the live terminal
/// under it. One view, so this Mac's sign-ins and a server's look like the same feature rather
/// than three copies of the same frame drifting apart.
struct LoginTerminalPanel<Accessory: View>: View {
    let session: LoginTerminalSession
    let title: String?
    let height: CGFloat
    let accessory: () -> Accessory

    init(
        session: LoginTerminalSession,
        title: String? = nil,
        height: CGFloat = 280,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.session = session
        self.title = title
        self.height = height
        self.accessory = accessory
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: InspectorLayout.gap) {
                Text(title ?? session.label)
                    .font(Typo.codeSmall)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(title ?? session.label)

                Spacer(minLength: 0)

                accessory()
            }
            .padding(.horizontal, InspectorLayout.inset)
            .frame(height: InspectorLayout.barHeight)
            .background(Palette.surfaceSunken)

            Hairline()

            LoginTerminal(session: session)
                .frame(height: height)
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner)
                .strokeBorder(Palette.border, lineWidth: Metrics.outline)
        )
    }
}

extension LoginTerminalPanel where Accessory == EmptyView {
    init(session: LoginTerminalSession, title: String? = nil, height: CGFloat = 280) {
        self.init(session: session, title: title, height: height) { EmptyView() }
    }
}

/// The SwiftUI face of a login terminal. It owns nothing: the live view comes from the session.
struct LoginTerminal: NSViewRepresentable {
    let session: LoginTerminalSession

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
        session.terminal.updateTheme()
    }
}
