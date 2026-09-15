import Foundation

/// The agent's CLI is not inside the project's execution environment, and the row that says so.
///
/// **The bug.** there-there.app's `.bloom/settings.toml` names `[execution] command =
/// [".bloom/docker/run"]`, which runs `docker compose run agent claude ...`. Its image installs
/// Codex and not Claude Code, so a Claude chat in that workspace died on status 127 with
/// `/usr/local/bin/docker-php-entrypoint: 9: exec: claude: not found`. The row drew that as
/// "Agent exited (127)" with the generic advice to open the row and send the turn again, and
/// sending again fails identically every time, because nothing about the turn was the problem.
///
/// Recognised by what a shell or a container runtime prints when it cannot find a command, and
/// only ever for a launch that went through an `[execution]` wrapper. Without the wrapper the CLI
/// is resolved by Bloom itself, `StreamingProcess` writes its own sentence when it is not there,
/// and `AgentExit` already reads that as `.missing`. Inside a wrapper Bloom resolved the wrapper,
/// so the name that could not be found is only ever in the wrapper's output.
///
/// There is no preflight. Asking the environment for `command -v claude` means running the wrapper
/// once more, and for a Docker wrapper that is a second `docker compose run`: a container start,
/// seconds at best and an image build at worst, in front of every session start in every such
/// workspace. The status and the output of the real launch answer the same question for free.
public struct AgentMissingFromEnvironment: Sendable, Hashable, Codable {
    /// The `[execution] name`, when the project gave one.
    public let environment: String?
    /// The `[execution] command`'s executable as the settings file wrote it, `.bloom/docker/run`,
    /// rather than the absolute path Bloom resolved it to, because that is the line a person
    /// looks for in their own file.
    public let command: String
    /// The command name the wrapper was asked to run, `claude`.
    public let cli: String

    public init(environment: String?, command: String, cli: String) {
        self.environment = environment.flatMap { $0.isEmpty ? nil : $0 }
        self.command = command
        self.cli = URL(fileURLWithPath: cli).lastPathComponent
    }

    // MARK: Recognising it

    /// Whether a wrapped launch ended because the environment has no such command.
    ///
    /// The shapes, as the tools print them:
    ///
    ///     /usr/local/bin/docker-php-entrypoint: 9: exec: claude: not found     dash, exec
    ///     sh: 1: claude: not found                                             dash
    ///     bash: line 1: claude: command not found                              bash
    ///     exec: "claude": executable file not found in $PATH                   Docker, runc
    ///     env: 'claude': No such file or directory                             coreutils env
    ///
    /// Quotes are dropped before matching so the last two read like the first three, and the name
    /// must start at a boundary so `myclaude: not found` is somebody else's missing command. The
    /// status is not required to be 127: `docker compose run` has been seen to hand back its own
    /// status rather than the container's, and the sentence is the more specific evidence.
    public static func recognises(status: Int?, output: String, cli: String) -> Bool {
        guard status != 0 else { return false }
        let name = URL(fileURLWithPath: cli).lastPathComponent
        guard !name.isEmpty else { return false }

        let text = AgentExit.stripEscapes(output).filter { !"\"'`".contains($0) }
        for phrase in notFoundPhrases {
            let needle = name + phrase
            var searched = text.startIndex..<text.endIndex
            while let found = text.range(of: needle, range: searched) {
                if found.lowerBound == text.startIndex || isBoundary(text[text.index(before: found.lowerBound)]) {
                    return true
                }
                searched = found.upperBound..<text.endIndex
            }
        }
        return false
    }

    static let notFoundPhrases = [
        ": not found",
        ": command not found",
        ": executable file not found",
        ": No such file or directory",
    ]

    /// A slash counts, because an absolute executable override arrives as
    /// `exec: /usr/local/bin/claude: not found`.
    private static func isBoundary(_ character: Character) -> Bool {
        character.isWhitespace || character == "/" || character == ":"
    }

    // MARK: What the row says

    /// The agent's own name when the command is one Bloom knows, the command otherwise.
    public var agent: String {
        AgentKind.allCases.first { $0.executableName == cli }?.label ?? cli
    }

    /// Short, because the label column is 176 points and the sentence is the summary's job.
    public var title: String { "Not installed" }

    public var summary: String {
        "\(agent) isn't installed in \(environmentPhrase)."
    }

    public var advice: String {
        """
        This project runs agents through \(command) (its [execution] setting), and that \
        environment has no \(cli) command. Install \(agent) in the project's image or \
        environment, or start this chat with an agent the environment has. Sending the turn again \
        will fail the same way until then. Nothing in this conversation was lost.
        """
    }

    private var environmentPhrase: String {
        environment.map { "the \($0) environment" } ?? "this project's execution environment"
    }
}
