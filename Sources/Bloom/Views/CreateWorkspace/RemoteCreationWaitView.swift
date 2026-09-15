import SwiftUI
import BloomCore

/// What the New Workspace window shows over its form while a server is still creating the
/// workspace, once the wait has lasted long enough to need saying.
///
/// It replaces a greyed out form with a tiny spinner in the corner, which is all the window used
/// to do while a server fetched a pull request, cut the worktree and, before protocol 15, ran the
/// whole setup script. The decisions (when to appear, when the server counts as not responding,
/// what the sentence says) are `RemoteCreationWait`, in the core and tested; this draws them.
struct RemoteCreationWaitView: View {
    let creation: RemoteWorkspaceCreation
    let server: ServerWindowModel
    /// The sentence naming the work the request implies, decided when Create was pressed.
    let activity: String
    let runsSetup: Bool
    let onCancel: () -> Void
    let onCloseWindow: () -> Void

    @State private var showsConnectionDetails = false

    var body: some View {
        if let startedAt = creation.startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let phase = RemoteCreationWait.phase(startedAt: startedAt, now: context.date,
                                                     isConnected: server.isConnected, lastHeardAt: server.lastHeardAt)
                if phase != .quiet {
                    panel(phase: phase, startedAt: startedAt, now: context.date)
                }
            }
        }
    }

    private func panel(phase: RemoteCreationWait.Phase, startedAt: Date, now: Date) -> some View {
        let isSilent = phase == .notResponding
        return VStack(spacing: Metrics.spacingWide) {
            Spacer(minLength: 0)
            if isSilent {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(Palette.warning)
                    .accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(isSilent ? "\(server.displayName) is not responding" : "Creating the workspace on \(server.displayName)…")
                .font(Typo.heading)
                .multilineTextAlignment(.center)
            Text(isSilent ? silenceSentence(startedAt: startedAt, now: now) : waitingSentence)
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
            Text("Waiting \(RemoteCreationWait.clock(now.timeIntervalSince(startedAt)))")
                .font(Typo.caption)
                .monospacedDigit()
                .foregroundStyle(Palette.textTertiary)
            HStack(spacing: Metrics.spacingWide) {
                if isSilent {
                    Button("Connection Details…") { showsConnectionDetails = true }
                        .popover(isPresented: $showsConnectionDetails) { ServerConnectionFailureView(server: server) }
                    Button("Cancel", action: onCancel)
                        .help("Stop waiting. The server may still finish creating the workspace.")
                    Button("Try Again") { creation.retry() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: onCancel)
                        .help("Stop waiting. The server may still finish creating the workspace.")
                    Button("Close Window", action: onCloseWindow)
                        .help("Keep creating in the background. The workspace appears in the sidebar when it is ready.")
                }
            }
            .padding(.top, Metrics.spacingWide)
            Spacer(minLength: 0)
        }
        .padding(Metrics.gutter * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface)
        .accessibilityElement(children: .contain)
    }

    private var waitingSentence: String {
        let setup = runsSetup
            ? " The setup script runs once the workspace exists, and its progress shows in the workspace."
            : ""
        return activity + setup + " You can close this window; the workspace appears in the sidebar when it is ready."
    }

    private func silenceSentence(startedAt: Date, now: Date) -> String {
        let lead = server.isConnected
            ? "Bloom has not heard from the server for \(Int(RemoteCreationWait.silence(startedAt: startedAt, now: now, lastHeardAt: server.lastHeardAt))) seconds."
            : "The connection to the server was lost."
        return lead + " The workspace may still be created, and would then appear in the sidebar."
    }
}
