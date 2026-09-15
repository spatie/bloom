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
                "-u", "NO_COLOR", "TERM=xterm-256color", "COLORTERM=truecolor",
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
            let hook: [String: Any] = ["type": "command", "command": Self.interactiveHookCommand, "timeout": 3]
            var hooks: [String: Any] = Dictionary(uniqueKeysWithValues: (events + ["StopFailure"]).map {
                ($0, [["hooks": [hook]]] as Any)
            })
            hooks["Notification"] = [[
                "matcher": "permission_prompt|idle_prompt",
                "hooks": [hook]
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
            arguments = resuming.map { ["resume", $0] } ?? []
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

    func interactiveSetupOutput(prompt: String?, log: String) -> String {
        let preview = String(String.UnicodeScalarView((prompt ?? "").unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var text = "\n  \u{1b}[1;36m" + label + "\u{1b}[0m\n"
            + "  Setting up your workspace\n\n"
        if !preview.isEmpty {
            text += "  \u{1b}[2mQueued prompt\u{1b}[0m\n  "
                + String(preview.prefix(180)) + (preview.count > 180 ? "…" : "") + "\n\n"
        }
        text += "  \u{1b}[2mSetup output · agent starts when ready\u{1b}[0m\n\n"
        return text + (log.isEmpty ? "  Waiting for setup output…\n" : log)
    }

    func interactiveScreenIsBusy(lines: [String]) -> Bool {
        var lines = lines
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        switch self {
        case .codex:
            return lines.suffix(12).contains {
                $0.range(of: #"^\s*[•●◦⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]?\s*[^>❯›]+\([0-9]+[smh][^)]* • [^)]* to interrupt\)\s*$"#,
                         options: .regularExpression) != nil
            }
        case .claudeCode:
            return lines.suffix(6).contains {
                $0.range(of: #"^\s*esc (?:to )?interrupt(?:\s*[·•].*)?\s*$"#,
                         options: [.regularExpression, .caseInsensitive]) != nil
            }
        case .cursor, .openCode, .grok:
            return false
        }
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
