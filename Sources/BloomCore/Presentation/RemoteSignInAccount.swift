import Foundation

/// An account signed in on a Bloom Server, over SSH, as the server's own service user.
///
/// The command lives here rather than beside the SSH launch because the sheet reads its output,
/// and the two have to agree: the line announcing an installation is printed by this command and
/// recognised by `RemoteSignInReading`, so changing one without the other is a test failure
/// rather than a sheet that says "Connecting" through a minute of npm.
public enum RemoteSignInAccount: Sendable, Hashable, CaseIterable {
    case github, codex, claude

    public var title: String {
        switch self {
        case .github: "GitHub"
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }

    /// Printed by the command before npm runs, so the sheet can say what is happening instead of
    /// showing npm's own notices. Plain ASCII, because it crosses a pty on a server whose locale
    /// is not ours.
    public static let installMarker = "bloom-sign-in: installing"

    /// The shell command run on the server.
    ///
    /// `GH_BROWSER=echo` because gh would otherwise try to open a browser on a machine that has
    /// none and report a failure the user cannot act on; with it, gh prints the device page and
    /// keeps polling, and the Mac opens that page instead.
    public var shellCommand: String {
        switch self {
        case .github:
            "GH_BROWSER=echo gh auth login --hostname github.com --git-protocol https --web && gh auth setup-git"
        case .codex:
            Self.installing(binary: "codex", package: "@openai/codex") + "codex login --device-auth"
        case .claude:
            Self.installing(binary: "claude", package: "@anthropic-ai/claude-code") + "claude auth login"
        }
    }

    private static func installing(binary: String, package: String) -> String {
        "export PATH=\"$HOME/.local/bin:$PATH\"; if ! command -v \(binary) >/dev/null; then "
            + "echo '\(installMarker)'; "
            + "npm install --global --prefix \"$HOME/.local\" \(package) || exit; fi; "
    }
}
