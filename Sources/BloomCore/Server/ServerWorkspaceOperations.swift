import Foundation

enum ServerWorkspaceOperations {
    static func perform(_ action: ServerWorkspaceAction, workspace: Workspace, store: Store, terminals: ServerTerminalService) async throws -> ServerResult {
        switch action {
        case .files:
            let files = try await Git.checkRaw(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: workspace.path)
            let paths = String(decoding: files.stdout, as: UTF8.self).split(separator: "\0").map(String.init)
            return .files(Array(Set(paths)).sorted())
        case .download(let path):
            return .download(try ServerFileOperations.download(workspace: workspace, path: path))
        case .writeFile(let path, let text, let revision):
            return .file(try ServerFileOperations.write(workspace: workspace, path: path, text: text, revision: revision))
        case .uploadFile(let name, let data):
            return .text(try ServerFileOperations.upload(workspace: workspace, name: name, data: data))
        case .commit(let message):
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServerFailure("Enter a commit message.") }
            try await Git.stageAll(in: workspace.path)
            _ = try await Git.commit(message: message, in: workspace.path, allowEmpty: false)
            return .text("Changes committed.")
        case .push:
            try await GitHub.push(worktree: workspace.path, branch: workspace.branch, setUpstream: true)
            return .text("Branch pushed.")
        case .createPullRequest(let title, let body, let draft):
            try await GitHub.push(worktree: workspace.path, branch: workspace.branch, setUpstream: true)
            let pull = try await GitHub.createPullRequest(worktree: workspace.path, base: workspace.baseBranch, title: title, body: body, draft: draft)
            return .text(pull.url)
        case .terminal(let name):
            return .terminal(try await terminal(workspace: workspace, name: name, store: store, service: terminals))
        case .newSession(let agent, let model, let effort, let permissionMode):
            guard agent.canRunWorkspaces, !model.isEmpty else { throw ServerFailure("Choose an available agent and model.") }
            let session = try await store.upsert(Session(workspaceID: workspace.id, model: model, effort: effort, agentKind: agent, permissionMode: permissionMode))
            return .created(session: session, workspace: workspace, setupSucceeded: nil)
        }
    }

    private static func terminal(workspace: Workspace, name: String, store: Store, service: ServerTerminalService) async throws -> ServerTerminal {
        guard !name.isEmpty, name.utf8.count <= 64,
              name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw ServerFailure("Use letters, numbers, hyphens or underscores for the terminal name.")
        }
        guard let executable = Shell.which("tmux") else { throw ServerFailure("Install tmux on the server to use terminals.") }
        let configuration = URL(fileURLWithPath: store.path).deletingLastPathComponent().appendingPathComponent("tmux.conf")
        if !FileManager.default.fileExists(atPath: configuration.path) {
            try TmuxSessions.configuration(defaultShell: LoginShell.path()).write(to: configuration, atomically: true, encoding: .utf8)
        }
        let command = TmuxCommand(executable: executable, socketName: TmuxSessions.socketName(databasePath: store.path), configPath: configuration.path)
        try await service.start(command: command, key: store.path, cwd: workspace.path)
        let session = TmuxSessions.sessionName(workspaceID: workspace.id, paneID: name)
        let exists = try await Shell.run(executable, command.arguments(["has-session", "-t", "=" + session]), cwd: workspace.path)
        if !exists.ok {
            let created = try await Shell.run(executable, command.arguments(["new-session", "-d", "-s", session, "-c", workspace.path]), cwd: workspace.path)
            if !created.ok {
                let raced = try await Shell.run(executable, command.arguments(["has-session", "-t", "=" + session]), cwd: workspace.path)
                guard raced.ok else { throw ServerFailure(created.stderr) }
            }
        }
        let socket = try await Shell.run(executable, command.arguments(["display-message", "-p", "-t", "=" + session, "#{socket_path}"]), cwd: workspace.path)
        guard socket.ok, socket.trimmed.hasPrefix("/") else { throw ServerFailure("Could not locate the server terminal socket.") }
        return ServerTerminal(executable: executable, socket: socket.trimmed, session: session)
    }
}
