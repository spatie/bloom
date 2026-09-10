import Foundation
import Testing
@testable import BloomCore

@Suite("Agent sign-in terminal launch")
struct TerminalLaunchScriptTests {
    @Test("Each agent's displayed command and execution arguments agree")
    func loginArguments() {
        #expect(AgentKind.claudeCode.loginArguments == ["auth", "login"])
        #expect(AgentKind.codex.loginArguments == ["login"])
        #expect(AgentKind.cursor.loginArguments == ["login"])
        #expect(AgentKind.openCode.loginArguments == ["auth", "login"])
        for kind in AgentKind.allCases {
            #expect(kind.loginCommand == ([kind.executableName] + kind.loginArguments).joined(separator: " "))
        }
    }

    @Test("The detected executable is separate from the working directory", arguments: AgentKind.allCases)
    func usesDetectedExecutable(kind: AgentKind) {
        let executable = "/opt/custom tools/" + kind.executableName
        let command = TerminalLaunchScript.shellCommand(
            directory: "/tmp/agent scratch", executable: executable, arguments: kind.loginArguments
        )
        let arguments = kind.loginArguments.map { "'\($0)'" }.joined(separator: " ")
        #expect(command == "cd '/tmp/agent scratch' && '\(executable)' \(arguments)")
    }

    @Test("Shell metacharacters in a path or argument remain literal")
    func quotesShellInput() {
        let command = TerminalLaunchScript.shellCommand(
            directory: "/tmp/it's a folder",
            executable: "/tmp/tool; echo unwanted",
            arguments: ["$(printf unwanted)", "a\"b\\c", ""]
        )
        #expect(command == #"cd '/tmp/it'\''s a folder' && '/tmp/tool; echo unwanted' '$(printf unwanted)' 'a"b\c' ''"#)
    }

    @Test("The shell runs an absolute executable with spaces and quotes without interpreting its arguments")
    func executesQuotedCommand() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bloom-terminal-launch-\(UUID().uuidString)")
            .appendingPathComponent("space ' quote; dollar$")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let executable = root.appendingPathComponent("test ' executable")
        try FileManager.default.createSymbolicLink(atPath: executable.path, withDestinationPath: "/usr/bin/printf")
        let argument = #"literal $(printf unwanted); 'quoted' "double" \slash"#
        let command = TerminalLaunchScript.shellCommand(
            directory: root.path, executable: executable.path, arguments: ["%s\n", argument]
        )
        let result = try await Shell.run("/bin/sh", ["-c", command], cwd: root.path)
        #expect(result.ok)
        #expect(result.stdout == argument + "\n")
        #expect(result.stderr.isEmpty)
    }
}
