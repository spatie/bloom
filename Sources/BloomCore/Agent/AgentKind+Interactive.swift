import Foundation

public extension AgentKind {
    func interactiveCommand(
        directory: String,
        prompt: String,
        sessionID: SessionID,
        model: String,
        effort: String,
        permissionMode: PermissionMode? = nil,
        resuming: String? = nil
    ) -> String? {
        guard let arguments = interactiveArguments(
            prompt: prompt, sessionID: sessionID, model: model,
            effort: effort, permissionMode: permissionMode, resuming: resuming
        ) else { return nil }
        let command = TerminalLaunchScript.shellCommand(
            directory: directory,
            executable: "/usr/bin/env",
            arguments: [
                "BLOOM_CLI_STATUS_FILE=\(Self.interactiveStatusURL(sessionID: sessionID).path)",
                executableName
            ] + arguments
        )
        guard command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return command
        }
        let encoded = Data(command.utf8).base64EncodedString()
        return "/bin/sh -c \"$(printf '%s' '\(encoded)' | /usr/bin/base64 -d)\""
    }

    func interactiveArguments(
        prompt: String,
        sessionID: SessionID,
        model: String,
        effort: String,
        permissionMode: PermissionMode? = nil,
        resuming: String? = nil
    ) -> [String]? {
        let events = [
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
            "PermissionRequest", "Stop", "SessionEnd"
        ]
        var arguments: [String]
        switch self {
        case .claudeCode:
            var hooks: [String: Any] = Dictionary(uniqueKeysWithValues: (events + ["StopFailure"]).map {
                ($0, [["hooks": [["type": "command", "command": Self.interactiveHookCommand, "timeout": 3]]]] as Any)
            })
            hooks["Notification"] = [[
                "matcher": "permission_prompt|idle_prompt",
                "hooks": [["type": "command", "command": Self.interactiveHookCommand, "timeout": 3]]
            ]]
            guard let data = try? JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.sortedKeys]),
                  let settings = String(data: data, encoding: .utf8) else { return nil }
            arguments = resuming.map { ["--resume", $0] } ?? ["--session-id", sessionID.rawValue]
            arguments += ["--settings", settings]
            if let permissionMode {
                arguments += ["--permission-mode", permissionMode.nearest(on: self).cliValue]
            }
            if !effort.isEmpty { arguments += ["--effort", effort] }
        case .codex:
            arguments = resuming.map { ["resume", $0, "--no-alt-screen"] } ?? ["--no-alt-screen"]
            if let permissionMode {
                arguments += ["--sandbox", CodexRunner.sandboxMode(for: permissionMode).rawValue,
                              "--ask-for-approval", CodexRunner.approvalPolicy(for: permissionMode).rawValue]
                if permissionMode == .autoReview { arguments += ["--approve-for-me"] }
            }
            for event in events {
                arguments += ["-c", "hooks.\(event)=[{hooks=[{type=\"command\",command=\(Self.interactiveTOMLString(Self.interactiveHookCommand)),timeout=3}]}]"]
            }
            if !effort.isEmpty {
                arguments += ["-c", "model_reasoning_effort=\(Self.interactiveTOMLString(effort))"]
            }
        case .cursor, .openCode, .grok:
            return nil
        }
        if !model.isEmpty {
            arguments += ["--model", self == .claudeCode ? ModelAlias.cliValue(for: model) : model]
        }
        if !prompt.isEmpty { arguments += ["--", prompt] }
        return arguments
    }

    static func interactiveStatusURL(
        sessionID: SessionID,
        base: URL = FileManager.default.temporaryDirectory,
        namespace: String = Bundle.main.bundleIdentifier ?? "unbundled"
    ) -> URL {
        let name = sessionID.rawValue.utf8.map { String(format: "%02x", $0) }.joined()
        let container = namespace.utf8.map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("bloom-cli-status", isDirectory: true)
            .appendingPathComponent(container, isDirectory: true)
            .appendingPathComponent(name + ".json")
    }

    static func interactiveHookState(data: Data) -> SessionState? {
        guard let value = interactiveHookObject(data: data),
              let event = value["hook_event_name"] as? String else { return nil }
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse": return .running
        case "PermissionRequest": return .waiting
        case "Stop", "SessionEnd": return .idle
        case "StopFailure": return .failed
        case "SessionStart": return value["source"] as? String == "compact" ? .running : .idle
        case "Notification":
            switch value["notification_type"] as? String {
            case "permission_prompt": return .waiting
            case "idle_prompt": return .idle
            default: return nil
            }
        default: return nil
        }
    }

    static func interactiveHookSessionID(data: Data) -> String? {
        guard let id = interactiveHookObject(data: data)?["session_id"] as? String,
              !id.isEmpty else { return nil }
        return id
    }

    // Stable across panes so Codex can remember the user's hook trust decision.
    static var interactiveHookCommand: String {
        #"umask 077; if [ -n "$BLOOM_CLI_STATUS_FILE" ]; then mkdir -p "$(dirname "$BLOOM_CLI_STATUS_FILE")" 2>/dev/null && bloom_status_tmp=$(mktemp "$BLOOM_CLI_STATUS_FILE.XXXXXX") && { cat > "$bloom_status_tmp" && mv -f "$bloom_status_tmp" "$BLOOM_CLI_STATUS_FILE"; } 2>/dev/null; fi; exit 0"#
    }

    private static func interactiveHookObject(data: Data) -> [String: Any]? {
        guard data.count <= 1_048_576 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func interactiveTOMLString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return string
    }
}
