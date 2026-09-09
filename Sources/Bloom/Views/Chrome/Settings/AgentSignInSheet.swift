import SwiftUI
import BloomCore

/// The CLI owns authentication and displays its own browser links and prompts in a real terminal.
/// A completed command stays visible: cancelling login can leave the old account connected, so
/// neither a clean exit nor cached account details are enough to announce a successful switch.
struct AgentSignInSheet: View {
    struct Request: Identifiable {
        let id = UUID()
        let kind: AgentKind
        let executable: String
        let isSwitchingAccount: Bool
        let directory = AgentScratchDirectory.current()
    }

    let request: Request
    let onExit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var session: LoginTerminalSession?
    @State private var failure: String?
    @State private var exit: TerminalExit?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Text("Sign in to \(request.kind.label)")
                .font(Typo.heading)
                .foregroundStyle(Palette.textPrimary)

            Text("Follow the prompts below to sign in. If a browser opens, finish signing in there.")
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if request.isSwitchingAccount {
                Text("This changes the account used by \(request.kind.label) on this Mac.")
                    .settingsFootnote()
            }

            if let session {
                VStack(spacing: 0) {
                    Text(session.label)
                        .font(Typo.codeSmall)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(session.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, InspectorLayout.inset)
                        .frame(height: InspectorLayout.barHeight)
                        .background(Palette.surfaceSunken)

                    Hairline()

                    LoginTerminal(session: session)
                        .frame(height: 280)
                }
                .clipShape(RoundedRectangle(cornerRadius: Metrics.corner))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.corner)
                        .strokeBorder(Palette.border, lineWidth: Metrics.outline)
                )
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.label)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if exit != nil {
                Text("Sign-in command finished. Close this window to review your account in Settings.")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Metrics.gutter) {
                Button("Copy sign-in command") {
                    Clipboard.copy(TerminalLaunchScript.shellCommand(
                        directory: request.directory,
                        executable: request.executable,
                        arguments: request.kind.loginArguments
                    ))
                }
                .help("Run this command in your own terminal to sign in.")

                Spacer()

                if failure != nil || exit != nil {
                    Button("Try again", action: start)
                }

                Button(session?.isRunning == true ? "Cancel" : "Done") {
                    session?.stop()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Metrics.pane)
        .frame(width: 660)
        .background(Palette.surface)
        .task { start() }
        .onDisappear { session?.stop() }
    }

    private func start() {
        session?.stop()
        exit = nil
        failure = nil
        session = LoginTerminalSession(
            executable: request.executable,
            arguments: request.kind.loginArguments,
            directory: request.directory,
            onExit: { result in
                exit = result
                if result != .exited(0) {
                    failure = "Sign-in did not finish. Check the terminal above, then try again."
                }
                onExit()
            }
        )
        if session == nil {
            failure = "The \(request.kind.label) executable is no longer available. Check its path in Settings."
        }
    }
}
