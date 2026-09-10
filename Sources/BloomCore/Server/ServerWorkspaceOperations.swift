import Foundation

enum ServerWorkspaceOperations {
    static func perform(_ action: ServerWorkspaceAction, workspace: Workspace, store: Store, terminals: ServerTerminalService) async throws -> ServerResult {
        switch action {
        case .archivePreview, .archive, .restore:
            throw ServerFailure("Workspace lifecycle actions must go through the owning runtime.")
        case .rename(let title):
            let name = try ServerSidebar.name(title)
            _ = try await store.update(workspaceID: workspace.id) { $0.name = name }
            return .accepted
        case .setPinned(let value):
            _ = try await store.update(workspaceID: workspace.id) { $0.pinned = value }
            return .accepted
        case .setUnread(let value):
            _ = try await store.update(workspaceID: workspace.id) { $0.unread = value }
            return .accepted
        case .setColour(let value):
            guard value == nil || WorkspaceColour.all.contains(where: { $0.hex == value }) else { throw ServerFailure("Choose a workspace colour from the menu.") }
            _ = try await store.update(workspaceID: workspace.id) { $0.colour = value }
            return .accepted
        case .browserAddress:
            guard let repo = try await store.repo(id: workspace.repoID) else { throw ServerFailure("This project's settings are unavailable.") }
            let environment = WorkspaceManager(store: store).environment(for: workspace, repo: repo, port: workspace.port)
            return .text(WorkspaceBrowserURL.read(worktree: workspace.path,
                settings: SettingsLoader.load(workspace: workspace.path, repo: repo.path),
                environment: environment, port: workspace.port))
        case .runSetup:
            guard let repo = try await store.repo(id: workspace.repoID) else { throw ServerFailure("This project's settings are unavailable.") }
            guard workspace.setupState != .running else { throw ServerFailure("Workspace setup is already running.") }
            let manager = WorkspaceManager(store: store)
            let port = await manager.ensurePort(for: workspace)
            guard await manager.runSetup(workspace: workspace, repo: repo, port: port, onOutput: { _ in }) else { throw ServerFailure("Workspace setup failed. Check the setup output before trying again.") }
            return .accepted

        case .notes:
            return .text(try await store.note(workspaceID: workspace.id)?.body ?? "")
        case .saveNotes(let body):
            guard body.utf8.count <= 1_048_576 else { throw ServerFailure("The note is too large.") }
            try await store.saveNote(workspaceID: workspace.id, body: body)
            return .accepted
        case .closeTerminal(let name):
            guard let executable = Shell.which("tmux") else { return .accepted }
            let session = TmuxSessions.sessionName(workspaceID: workspace.id, paneID: name)
            let command = TmuxCommand(executable: executable, socketName: TmuxSessions.socketName(databasePath: store.path), configPath: URL(fileURLWithPath: store.path).deletingLastPathComponent().appendingPathComponent("tmux.conf").path)
            _ = try await Shell.run(executable, command.arguments(["kill-session", "-t", "=" + session]), cwd: workspace.path)
            return .accepted
        case .runScripts:
            guard let repo = try await store.repo(id: workspace.repoID) else { throw ServerFailure("The workspace's project is unavailable.") }
            return .runScripts(SettingsLoader.load(workspace: workspace.path, repo: repo.path).runScripts)
        case .runScript(let id):
            guard let repo = try await store.repo(id: workspace.repoID),
                  let script = SettingsLoader.load(workspace: workspace.path, repo: repo.path).runScripts.first(where: { $0.id == id }) else {
                throw ServerFailure("This run script is no longer configured in the project.")
            }
            let pane = ServerTerminalPane(id: UUID().uuidString, title: script.name)
            let terminal = try await terminal(workspace: workspace, name: pane.id.rawValue, store: store, service: terminals)
            let target = ["-S", terminal.socket, "send-keys", "-t", "=" + terminal.session + ":"]
            let typed = try await Shell.run(terminal.executable, target + ["-l", "--", script.command], cwd: workspace.path)
            guard typed.ok else { throw ServerFailure(typed.stderr) }
            let submitted = try await Shell.run(terminal.executable, target + ["Enter"], cwd: workspace.path)
            guard submitted.ok else { throw ServerFailure(submitted.stderr) }
            return .terminalPane(pane)
        case .pullRequest:
            let pull = try await GitHub.pullRequest(forBranch: workspace.branch, worktree: workspace.path, maxAge: .seconds(30))
            await PullRequestNumber.record(pull, for: workspace, in: store)
            return .text(pull?.url ?? "")
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
            await PullRequestNumber.record(pull, for: workspace, in: store)
            return .text(pull.url)
        case .terminal(let name):
            return .terminal(try await terminal(workspace: workspace, name: name, store: store, service: terminals))
        case .newSession(let agent, let model, let effort, let permissionMode):
            let session = try await createSession(workspace: workspace, controls: ComposerControls(model: model, effort: effort, agentKind: agent, permissionMode: permissionMode), store: store)
            return .created(session: session, workspace: workspace, setupSucceeded: nil)
        }
    }

    static func createSession(workspace: Workspace, controls: ComposerControls, title: String? = nil, store: Store) async throws -> Session {
        guard controls.agentKind.canRunWorkspaces, !controls.model.isEmpty else { throw ServerFailure("Choose an available agent and model.") }
        let existing = try await store.sessions(workspaceID: workspace.id)
        let title = title ?? PaneNaming.nextTitle(base: PaneNaming.chat, taken: existing.map(\.title))
        let session = try await store.upsert(Session(workspaceID: workspace.id,
            title: title, model: controls.model, effort: controls.effort, agentKind: controls.agentKind, permissionMode: controls.permissionMode))
        try await ServerComposer.save(controls, session: session, store: store)
        return session
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
            var arguments = ["new-session", "-d", "-s", session, "-c", workspace.path]
            let execution = try await WorkspaceExecution.resolve(store: store, workspace: workspace)
            for (key, value) in execution.environment.sorted(by: { $0.key < $1.key }) {
                arguments += ["-e", "\(key)=\(value)"]
            }
            if let shell = execution.terminalCommand { arguments.append(shell) }
            let created = try await Shell.run(executable, command.arguments(arguments), cwd: workspace.path)
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
