import Foundation
import Testing
@testable import BloomCore

@Suite("Interactive CLI agents")
struct InteractiveAgentTests {
    @Test("Interactive arguments preserve the prompt and normal permission choices")
    func arguments() throws {
        let id = SessionID.new()
        let prompt = "--help\n$(touch unwanted); 'quoted'"
        let claude = try #require(AgentKind.claudeCode.interactiveArguments(
            prompt: prompt, sessionID: id, model: "opus", effort: "high", permissionMode: .plan
        ))
        #expect(claude.suffix(2) == ["--", prompt])
        #expect(claude.contains("--session-id"))
        #expect(claude.contains(id.rawValue))
        #expect(claude.contains("plan"))
        #expect(!claude.contains("--print"))
        let index = try #require(claude.firstIndex(of: "--settings"))
        let settings = try #require(JSONSerialization.jsonObject(with: Data(claude[index + 1].utf8)) as? [String: Any])
        let hooks = try #require(settings["hooks"] as? [String: Any])
        #expect(hooks["PermissionRequest"] != nil)
        let notifications = try #require(hooks["Notification"] as? [[String: Any]])
        #expect(notifications.first?["matcher"] as? String == "permission_prompt|idle_prompt")

        let codex = try #require(AgentKind.codex.interactiveArguments(
            prompt: prompt, sessionID: id, model: "gpt-test", effort: "high", permissionMode: .acceptEdits
        ))
        #expect(codex.suffix(2) == ["--", prompt])
        #expect(codex.contains("--no-alt-screen"))
        #expect(codex.contains("workspace-write"))
        #expect(codex.contains("on-request"))
        #expect(!codex.contains("exec"))
        #expect(!codex.contains("--dangerously-bypass-hook-trust"))
        #expect(codex.contains("model_reasoning_effort=\"high\""))
    }

    @Test("Claude model aliases use the same translation as managed chats")
    func modelAlias() throws {
        let arguments = try #require(AgentKind.claudeCode.interactiveArguments(
            prompt: "", sessionID: .new(), model: "opus-5-1m", effort: ""
        ))
        let index = try #require(arguments.firstIndex(of: "--model"))
        #expect(arguments[index + 1] == ModelAlias.cliValue(for: "opus-5-1m"))
    }

    @Test("Shell launch delivers literal prompt text to the CLI")
    func literalPrompt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-interactive-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeCLI = root.appendingPathComponent("claude")
        try Data("#!/bin/sh\nfor argument do printf '%s\\n' \"$argument\"; done\n".utf8).write(to: fakeCLI)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        let prompt = "first line\n$(touch unwanted); 'quoted' `touch unwanted`"
        let command = try #require(AgentKind.claudeCode.interactiveCommand(
            directory: root.path, prompt: prompt, sessionID: .new(), model: "", effort: "", permissionMode: .auto
        ))
        #expect(!command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }))
        let result = try await Shell.run("/bin/sh", ["-c", command], env: ["PATH": root.path + ":/usr/bin:/bin"])
        #expect(result.ok)
        #expect(result.stdout.hasSuffix("--\n" + prompt + "\n"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unwanted").path))
    }

    @Test("Resume preserves native identity without replaying the opening prompt", arguments: [AgentKind.claudeCode, .codex])
    func resume(agent: AgentKind) throws {
        let arguments = try #require(agent.interactiveArguments(
            prompt: "", sessionID: .new(), model: "", effort: "", resuming: "native-session"
        ))
        #expect(arguments.prefix(2) == [agent == .claudeCode ? "--resume" : "resume", "native-session"])
        #expect(!arguments.contains("--session-id"))
        #expect(!arguments.contains("--permission-mode"))
        #expect(!arguments.contains("--sandbox"))
        #expect(!arguments.contains("--model"))
        #expect(!arguments.contains("--"))
    }

    @Test("Lifecycle hook states use events, never process presence", arguments: [
        ("UserPromptSubmit", SessionState.running), ("PreToolUse", .running), ("PostToolUse", .running),
        ("PermissionRequest", .waiting), ("Stop", .idle), ("SessionStart", .idle),
        ("SessionEnd", .idle), ("StopFailure", .failed)
    ])
    func hookState(event: String, expected: SessionState) {
        let data = Data("{\"hook_event_name\":\"\(event)\",\"session_id\":\"native-id\"}".utf8)
        #expect(AgentKind.interactiveHookState(data: data) == expected)
        #expect(AgentKind.interactiveHookSessionID(data: data) == "native-id")
    }

    @Test("Malformed and unrelated hooks do not invent activity")
    func malformedHooks() {
        #expect(AgentKind.interactiveHookState(data: Data("broken".utf8)) == nil)
        #expect(AgentKind.interactiveHookState(data: Data("{\"hook_event_name\":\"unknown\"}".utf8)) == nil)
        #expect(AgentKind.interactiveHookSessionID(data: Data("{\"session_id\":\"\"}".utf8)) == nil)
        let compact = Data("{\"hook_event_name\":\"SessionStart\",\"source\":\"compact\"}".utf8)
        #expect(AgentKind.interactiveHookState(data: compact) == .running)
    }

    @Test("Hook snapshots recover missed events through the session lifecycle")
    func recoversMissedEvents() {
        let states: [SessionState] = [.idle, .running, .waiting, .failed, .cancelled]
        let date = Date(timeIntervalSince1970: 100)
        for initial in states {
            for observed in states {
                var session = Session(workspaceID: WorkspaceID("workspace"), state: initial)
                session.applyInteractiveState(observed, at: date)
                #expect(session.state == observed)
                if initial != observed { #expect(session.updatedAt == date) }
            }
        }
    }

    @Test("Hook writer replaces complete JSON and never blocks the CLI")
    func writesHook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-hook-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = AgentKind.interactiveStatusURL(sessionID: SessionID("../unsafe"), base: root)
        #expect(destination.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "bloom-cli-status")
        let payload = "{\"hook_event_name\":\"Stop\",\"session_id\":\"native\"}"
        let result = try await Shell.run("/bin/sh", ["-c", AgentKind.interactiveHookCommand],
                                         env: ["BLOOM_CLI_STATUS_FILE": destination.path], stdin: payload)
        #expect(result.ok)
        #expect(result.stdout.isEmpty)
        #expect(try String(contentsOf: destination, encoding: .utf8) == payload)
        let failed = try await Shell.run("/bin/sh", ["-c", AgentKind.interactiveHookCommand],
                                         env: ["BLOOM_CLI_STATUS_FILE": "/dev/null/impossible"])
        #expect(failed.ok)
        #expect(failed.stdout.isEmpty)
    }

    @Test("Generated resume commands remain offerable despite hook options", arguments: [AgentKind.claudeCode, .codex])
    func offerResume(agent: AgentKind) throws {
        let command = try #require(agent.interactiveCommand(
            directory: "/tmp/worktree", prompt: "", sessionID: .new(),
            model: "", effort: "", resuming: "native-session"
        ))
        #expect(TerminalCommandMemory.offerable(command, maximumLength: 262_144) == command)
    }

    @Test("Copied session IDs cannot share hook files between app builds")
    func isolatedStatusFiles() {
        let id = SessionID("copied-session")
        let production = AgentKind.interactiveStatusURL(sessionID: id, namespace: "be.spatie.bloom")
        let development = AgentKind.interactiveStatusURL(sessionID: id, namespace: "be.spatie.bloom.dev")
        #expect(production != development)
    }
}
