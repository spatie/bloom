import SwiftUI
import BloomCore

/// What a GitHub action does when there is no GitHub access: one modal, one sentence, and a button
/// that actually signs you in.
///
/// The primary button runs the login here rather than sending the user somewhere. `gh auth login`
/// is interactive from end to end, so the alternatives were all worse: running it in a hidden
/// subprocess leaves it waiting on a question nobody can see, opening Terminal.app hands the job
/// to another program and needs an automation permission to do it, and `--web` with the device
/// code scraped out of the output means parsing a CLI's prose and reprinting it in our own words.
/// A real terminal in the sheet is the honest version of all three: the CLI asks its own questions
/// in its own words, the one-time code is legible because it is the CLI's own output, and the user
/// presses Return where they are already looking.
///
/// Nothing here reads the terminal's output. The device code on screen is the CLI talking to the
/// person in front of it; it is never scraped, stored, logged, or put on the pasteboard, and
/// neither is anything else that scrolls past. The only text this view copies is the command.
struct GitHubSignInSheet: View {
    let request: GitHubSignIn.Request
    let onFinish: (Bool) -> Void

    /// Moves as the flow does: a missing gh becomes a signed out gh once Homebrew has finished.
    @State private var access: GitHubAvailability.State
    @State private var phase: Phase = .idle
    @State private var session: GitHubLoginSession?
    @State private var isShowingOptions = false

    private enum Phase: Equatable {
        /// Waiting for the user to press the primary button.
        case idle
        /// The command is running in the terminal and the user is answering it.
        case running
        /// The command has finished and gh is being asked whether it worked.
        case checking
        case connected
        case failed(String)
    }

    /// Long enough to see that it worked, short enough not to be a step of its own.
    private static let successPause = Duration.milliseconds(700)
    private static let manualURL = "https://cli.github.com/manual/gh_auth_login"
    private static let downloadURL = "https://cli.github.com"

    init(request: GitHubSignIn.Request, onFinish: @escaping (Bool) -> Void) {
        self.request = request
        self.onFinish = onFinish
        _access = State(initialValue: request.access)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            header
            if let session {
                terminal(session)
            }
            statusLine
            footer
        }
        .padding(Metrics.pane)
        .frame(width: 660)
        .background(Palette.surface)
        // Whatever route the sheet leaves by, including Escape and the close cross, the child
        // process goes with it. A `gh auth login` waiting forever on a terminal nobody can see is
        // the failure this exists to avoid.
        .onDisappear { session?.stop() }
    }

    // MARK: - Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: InspectorLayout.tight) {
            Text(title)
                .font(Typo.heading)
                .foregroundStyle(Palette.textPrimary)

            Text(sentence)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func terminal(_ session: GitHubLoginSession) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: InspectorLayout.gap) {
                Text("Running \(session.label)")
                    .font(Typo.codeSmall)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button("Stop", systemImage: "xmark") { stop() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(Palette.textTertiary)
                    .help("Stop and close")
            }
            .padding(.horizontal, InspectorLayout.inset)
            .frame(height: InspectorLayout.barHeight)
            .background(Palette.surfaceSunken)

            Hairline()

            // Wide enough that gh's questions do not wrap mid word and that the one-time code and
            // the device URL are both readable on one line, which matters because the code is the
            // one thing the user has to copy by eye. Roughly ninety columns at the default
            // terminal size, and eighteen rows.
            GitHubLoginTerminal(session: session)
                .frame(height: 280)
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner).strokeBorder(Palette.border)
        )
    }

    @ViewBuilder
    private var statusLine: some View {
        switch phase {
        case .idle, .running:
            EmptyView()
        case .checking:
            HStack(spacing: InspectorLayout.gap) {
                ProgressView().controlSize(.small)
                Text("Checking with the GitHub CLI")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
            }
        case .connected:
            Label("Connected to GitHub", systemImage: "checkmark.circle.fill")
                .font(Typo.label)
                .foregroundStyle(Palette.positive)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(Typo.label)
                .foregroundStyle(Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            if isShowingOptions { options }

            HStack(spacing: InspectorLayout.gap) {
                Button(isShowingOptions ? "Fewer options" : "Other sign-in options") {
                    isShowingOptions.toggle()
                }
                .linkButton()
                .font(Typo.label)

                Spacer(minLength: Metrics.gutter)

                Button("Cancel", role: .cancel) { stop() }
                    .keyboardShortcut(.cancelAction)

                primaryButton
            }
        }
    }

    /// Everything that is not "sign in here", for the people who have their own way of doing it.
    /// The command is offered as text to copy because a terminal somewhere else is a perfectly
    /// good answer, and Bloom notices the result either way.
    private var options: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            Text(
                "You can sign in anywhere: run gh auth login in your own terminal, or use a "
                    + "token you already have. Bloom re-checks on its own, and Check again asks "
                    + "straight away."
            )
            .font(Typo.micro)
            .foregroundStyle(Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: InspectorLayout.gap) {
                Button("Copy gh auth login") { Clipboard.copy("gh auth login") }
                Button("Check again") { recheck() }
                Button("GitHub CLI manual") { GitHubBridge.open(Self.manualURL) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(Metrics.spacingWide)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
    }

    /// Tinted explicitly, like every other prominent button in the app: untinted it follows the
    /// system accent and renders as grey glass on macOS 26.
    @ViewBuilder
    private var primaryButton: some View {
        switch phase {
        case .idle:
            if access == .notInstalled, !canBrew {
                Button("Open cli.github.com") { GitHubBridge.open(Self.downloadURL) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accentFill)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(primaryTitle, systemImage: "play.fill") { start() }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accentFill)
                    .keyboardShortcut(.defaultAction)
            }
        case .running, .checking:
            Button(primaryTitle, systemImage: "play.fill") {}
                .buttonStyle(.borderedProminent)
                .tint(Palette.accentFill)
                .disabled(true)
        case .connected:
            Button("Continue") { onFinish(true) }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accentFill)
                .keyboardShortcut(.defaultAction)
        case .failed:
            Button("Try again", systemImage: "arrow.clockwise") { start() }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accentFill)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Copy

    private var title: String {
        access == .notInstalled ? "Install the GitHub CLI" : "Connect GitHub"
    }

    private var sentence: String {
        switch access {
        case .notInstalled where canBrew:
            "This action needs the gh command, and it is not installed on this Mac. "
                + "Homebrew can install it here."
        case .notInstalled:
            "This action needs the gh command, and it is not installed on this Mac. "
                + "Install it from cli.github.com, then come back."
        default:
            "This action needs GitHub access. Sign in with the GitHub CLI to continue."
        }
    }

    private var primaryTitle: String {
        access == .notInstalled ? "Run brew install gh" : "Run gh auth login"
    }

    private var canBrew: Bool { Shell.which("brew") != nil }

    // MARK: - Actions

    /// Starts whichever command this state needs, in a terminal the user can answer.
    private func start() {
        session?.stop()

        let executable = access == .notInstalled ? "brew" : "gh"
        let arguments = access == .notInstalled ? ["install", "gh"] : ["auth", "login"]

        guard let session = GitHubLoginSession(
            executable: executable,
            arguments: arguments,
            directory: request.directory,
            onExit: { _ in finished() }
        ) else {
            phase = .failed("\(executable) is not on this Mac.")
            return
        }

        self.session = session
        phase = .running
    }

    /// The command has ended. Whether it worked is gh's answer to give, not the exit status's:
    /// a login the user backed out of exits zero just the same.
    private func finished() {
        phase = .checking
        Task {
            let state = await GitHubAvailability.shared.check(force: true)
            switch state {
            case .ready:
                phase = .connected
                try? await Task.sleep(for: Self.successPause)
                onFinish(true)
            case .signedOut where access == .notInstalled:
                // Homebrew did its half. The sentence and the button become the login's.
                access = .signedOut
                phase = .idle
            case .signedOut:
                phase = .failed("The GitHub CLI is still signed out. You can run it again.")
            case .notInstalled:
                phase = .failed("The gh command is still not on this Mac.")
            case .unknown:
                phase = .failed("Bloom could not tell whether that worked.")
            }
        }
    }

    private func recheck() {
        phase = .checking
        Task {
            guard await GitHubAvailability.shared.check(force: true) == .ready else {
                phase = .failed("Still no GitHub access.")
                return
            }
            phase = .connected
            try? await Task.sleep(for: Self.successPause)
            onFinish(true)
        }
    }

    private func stop() {
        session?.stop()
        onFinish(false)
    }
}
