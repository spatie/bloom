import Testing
import Foundation
@testable import BloomCore

@Suite("Agent missing from the execution environment")
struct AgentMissingFromEnvironmentTests {
    private static let docker = AgentMissingFromEnvironment(environment: "Docker", command: ".bloom/docker/run", cli: "claude")

    @Test("the not-found shapes shells and container runtimes print are recognised", arguments: [
        "/usr/local/bin/docker-php-entrypoint: 9: exec: claude: not found",
        "sh: 1: claude: not found",
        "bash: line 1: claude: command not found",
        "/bin/bash: claude: command not found",
        #"OCI runtime exec failed: exec failed: unable to start container process: exec: "claude": executable file not found in $PATH: unknown"#,
        "env: 'claude': No such file or directory",
        "exec: /usr/local/bin/claude: not found",
        "\u{1B}[31msh: 1: claude: not found\u{1B}[0m",
    ])
    func recognisesNotFound(output: String) {
        #expect(AgentMissingFromEnvironment.recognises(status: 127, output: output, cli: "claude"))
    }

    @Test("an absolute executable override is matched by its command name")
    func absoluteOverride() {
        #expect(AgentMissingFromEnvironment.recognises(
            status: 127, output: "sh: 1: claude: not found", cli: "/opt/homebrew/bin/claude"))
    }

    @Test("somebody else's missing command, a clean status or an unrelated error is not this", arguments: [
        (127, "sh: 1: myclaude: not found"),
        (127, "sh: 1: codex: not found"),
        (127, "Error: the model refused the request"),
        (0, "sh: 1: claude: not found"),
    ])
    func rejects(status: Int, output: String) {
        #expect(!AgentMissingFromEnvironment.recognises(status: status, output: output, cli: "claude"))
    }

    @Test("the row names the agent, the environment and the command in the settings file's words")
    func wording() {
        let missing = Self.docker
        #expect(missing.title == "Not installed")
        #expect(missing.summary == "Claude Code isn't installed in the Docker environment.")
        #expect(missing.advice.contains("runs agents through .bloom/docker/run (its [execution] setting)"))
        #expect(missing.advice.contains("has no claude command"))
        #expect(!missing.advice.contains("send the turn again"))
    }

    @Test("an unnamed environment is still described")
    func unnamed() {
        let missing = AgentMissingFromEnvironment(environment: "", command: "bin/run", cli: "codex")
        #expect(missing.summary == "Codex isn't installed in this project's execution environment.")
    }

    @Test("the payload a wrapped run writes reads back as the specific row, as a remote Mac would read it")
    func payloadRoundTrip() throws {
        let stderr = "/usr/local/bin/docker-php-entrypoint: 9: exec: claude: not found"
        let run = try #require(UnfinishedRun.of(
            status: 127, sawResult: false, state: .running, stderr: stderr,
            command: "/home/bloom/workspace/.bloom/docker/run", execution: Self.docker))

        let exit = AgentExit.decode(run.payload)

        #expect(exit.cause == .missingInEnvironment(Self.docker))
        #expect(exit.title == "Not installed")
        #expect(exit.summary == "Claude Code isn't installed in the Docker environment.")
        #expect(!exit.advice.contains("Bloom ran"))
        #expect(exit.detail == stderr)
    }

    @Test("the same output from a host launch keeps the generic reading")
    func hostLaunchIsUnchanged() throws {
        let run = try #require(UnfinishedRun.of(
            status: 127, sawResult: false, state: .running, stderr: "sh: 1: claude: not found", command: "/usr/bin/claude"))
        #expect(AgentExit.decode(run.payload).cause == .reported("sh: 1: claude: not found"))
    }

    @Test("a wrapped launch that failed for another reason keeps the generic reading")
    func wrappedOtherFailure() throws {
        let run = try #require(UnfinishedRun.of(
            status: 1, sawResult: false, state: .running, stderr: "Error: connection closed by the server",
            command: "/w/.bloom/docker/run", execution: Self.docker))
        #expect(AgentExit.decode(run.payload).cause == .reported("Error: connection closed by the server"))
    }

    @Test("only a wrapped execution carries the context, named as the settings file wrote it")
    func executionContext() {
        #expect(WorkspaceExecution().missingAgentContext(cli: "claude") == nil)
        let wrapped = WorkspaceExecution(commandPrefix: ["/w/.bloom/docker/run"], name: "Docker", configuredCommand: ".bloom/docker/run")
        #expect(wrapped.missingAgentContext(cli: "claude") == Self.docker)
    }
}
