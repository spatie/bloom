import Testing
import Foundation
@testable import BloomCore

@Suite("Workspace execution", .scratchDirectory)
struct WorkspaceExecutionTests {
    private func fixture() throws -> (Repo, Workspace) {
        let root = TestScratch.unique("execution root")
        let path = TestScratch.unique("execution branch")
        for directory in [root, path] {
            try FileManager.default.createDirectory(atPath: directory + "/.bloom", withIntermediateDirectories: true)
        }
        let repo = Repo(name: "Fixture", path: root)
        return (repo, Workspace(repoID: repo.id, name: "Branch", branch: "feature", path: path, baseBranch: "main"))
    }

    private func write(_ text: String, to path: String, executable: Bool = false) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
    }

    @Test("branch settings and script files win while root local overrides remain effective")
    func settingsFollowBranch() throws {
        let (repo, workspace) = try fixture()
        try write("[scripts]\nsetup = 'main'", to: repo.path + "/.bloom/settings.toml")
        try write("[scripts]\nsetup_file = '.bloom/setup'\n[execution]\ncommand = ['.bloom/exec']\nname = 'Docker'", to: workspace.path + "/.bloom/settings.toml")
        try write("echo branch", to: workspace.path + "/.bloom/setup")
        let branch = SettingsLoader.load(workspace: workspace.path, repo: repo.path)
        #expect(branch.setupScript == "echo branch")
        #expect(branch.executionCommand == [".bloom/exec"])
        #expect(branch.executionName == "Docker")
        try write("[scripts]\nsetup = 'machine override'", to: repo.path + "/.bloom/settings.local.toml")
        #expect(SettingsLoader.load(workspace: workspace.path, repo: repo.path).setupScript == "machine override")
        try write("[scripts]\nsetup = 'workspace override'", to: workspace.path + "/.bloom/settings.local.toml")
        #expect(SettingsLoader.load(workspace: workspace.path, repo: repo.path).setupScript == "workspace override")
    }

    @Test("wrapper preserves argv boundaries and workspace environment through a real subprocess")
    func forwardsArguments() async throws {
        let (repo, workspace) = try fixture()
        try write("[execution]\ncommand = ['.bloom/exec']", to: workspace.path + "/.bloom/settings.toml")
        try write("#!/bin/sh\nexec \"$@\"\n", to: workspace.path + "/.bloom/exec", executable: true)
        let execution = try WorkspaceExecution.resolve(workspace: workspace, repo: repo, environment: ["BLOOM_PORT": "3190"])
        let spec = execution.wrapping(AgentLaunch(executable: "/bin/sh", arguments: ["-c", "printf '%s\\n' \"$BLOOM_PORT\" \"$1\"", "sh", "space ' and $(false)"], cwd: workspace.path, environment: Shell.environment()))
        let process = StreamingProcess(executable: spec.executable, arguments: spec.arguments, cwd: spec.cwd, environment: spec.environment)
        var lines: [String] = []
        for try await line in process.lines { lines.append(line) }
        #expect(await process.exitStatus == 0)
        #expect(lines == ["3190", "space ' and $(false)"])
    }

    @Test("an escaping symlink or non-executable wrapper fails instead of running tools on the host")
    func rejectsInvalidWrapper() throws {
        let (repo, workspace) = try fixture()
        let settings = workspace.path + "/.bloom/settings.toml"
        try write("[execution]\ncommand = ['.bloom/exec']", to: settings)
        try FileManager.default.createSymbolicLink(atPath: workspace.path + "/.bloom/exec", withDestinationPath: "/bin/sh")
        #expect(throws: WorkspaceExecution.Failure.self) {
            try WorkspaceExecution.resolve(workspace: workspace, repo: repo, environment: [:])
        }
        try FileManager.default.removeItem(atPath: workspace.path + "/.bloom/exec")
        try write("#!/bin/sh\n", to: workspace.path + "/.bloom/exec")
        #expect(throws: WorkspaceExecution.Failure.self) {
            try WorkspaceExecution.resolve(workspace: workspace, repo: repo, environment: [:])
        }
    }

    @Test("Codex launches through the wrapper with protocol arguments intact")
    func codexPrefix() {
        let launch = CodexClient.launch(.init(executable: "/opt/bin/codex", commandPrefix: ["/workspace/.bloom/exec", "argument with spaces"], cwd: "/workspace"))
        #expect(launch.executable == "/workspace/.bloom/exec")
        #expect(launch.arguments == ["argument with spaces", "/opt/bin/codex", "app-server", "--listen", "stdio://"])
    }

    @Test("wrapped agents omit the host bridge while ordinary agents keep it")
    func bridgeRegistration() async throws {
        let bridge = BridgeAttachment(shimPath: "/host/bloom-bridge", socketPath: "/host/bridge.sock", token: "test", role: .parent)
        let host = CodexClient.launch(.init(cwd: "/workspace", bridge: bridge))
        let wrapped = CodexClient.launch(.init(commandPrefix: ["/workspace/.bloom/exec"], cwd: "/workspace", bridge: bridge))
        #expect(host.arguments.contains(where: { $0.contains("mcp_servers.") }))
        #expect(!wrapped.arguments.contains(where: { $0.contains("mcp_servers.") }))

        let (repo, workspace) = try fixture()
        let store = try makeTestStore("execution-agent")
        try await store.upsert(repo)
        try await store.upsert(workspace)
        let session = try await store.upsert(Session(workspaceID: workspace.id))
        let box = ProcessBox()
        let runner = AgentRunner(workspacePath: workspace.path, session: session, store: store, mcpConfigPath: "/host/mcp.json", makeProcess: box.factory)
        #expect(await runner.launch().arguments.contains("--mcp-config"))
        try write("[execution]\ncommand = ['.bloom/exec']", to: workspace.path + "/.bloom/settings.toml")
        try write("#!/bin/sh\nexec \"$@\"\n", to: workspace.path + "/.bloom/exec", executable: true)
        try await runner.send("fixture")
        let launch = await runner.launch()
        #expect(!launch.arguments.contains("--mcp-config"))
        #expect(launch.environment["BLOOM_WORKSPACE_PATH"] == workspace.path)
        #expect(launch.environment["BLOOM_ROOT_PATH"] == repo.path)
        await runner.cancel()
    }

    @Test("creating from a feature branch runs that branch's setup file on the host")
    func branchSetup() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try await Shell.check("git", ["checkout", "-b", "container-config"], cwd: repo.path)
        try repo.write(".bloom/settings.toml", "file_include_globs = []\n[scripts]\nsetup_file = '.bloom/setup'\n[execution]\ncommand = ['.bloom/missing-wrapper']")
        try repo.write(".bloom/setup", "#!/bin/sh\nprintf 'branch setup' > setup-proof.txt\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.path + "/.bloom/setup")
        try await repo.commit("Add branch setup")
        try await Shell.check("git", ["checkout", "main"], cwd: repo.path)
        try repo.write(".env", "ROOT_SECRET=must-stay-here")
        let store = try makeTestStore("execution-setup")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Container branch", baseBranch: "container-config")
        #expect(!TempRepo(existing: workspace.path).exists(".env"))
        #expect(workspace.setupState == .pending)
        let succeeded = await manager.runSetup(workspace: workspace, repo: registered, port: 3190) { _ in }
        #expect(succeeded)
        #expect(TempRepo(existing: workspace.path).read("setup-proof.txt") == "branch setup")
        #expect(!repo.exists("setup-proof.txt"))
    }

    @Test("server run scripts start inside the workspace wrapper")
    func serverScriptUsesWrapper() async throws {
        guard let tmux = Shell.which("tmux") else { return }
        let (repo, workspace) = try fixture()
        try write("[execution]\ncommand = ['.bloom/exec']\n[scripts.run.verify]\ncommand = 'printf \"%s\\n\" \"$WRAPPER_ACTIVE:$BLOOM_PORT\" > wrapped-run.txt'", to: workspace.path + "/.bloom/settings.toml")
        try write("#!/bin/sh\nexport WRAPPER_ACTIVE=yes\nexec \"$@\"\n", to: workspace.path + "/.bloom/exec", executable: true)
        let store = try makeTestStore("execution-terminal")
        try await store.upsert(repo)
        try await store.upsert(workspace)
        let service = ServerTerminalService()
        let result = try await ServerWorkspaceOperations.perform(.runScript(id: "verify"), workspace: workspace, store: store, terminals: service)
        guard case .terminalPane = result else { Issue.record("Missing run terminal"); await service.shutdown(); return }
        await waitUntil("wrapped run script") { FileManager.default.fileExists(atPath: workspace.path + "/wrapped-run.txt") }
        let output = try String(contentsOfFile: workspace.path + "/wrapped-run.txt", encoding: .utf8)
        let port = try #require(try await store.workspace(id: workspace.id)?.port)
        #expect(output == "yes:\(port)\n")
        _ = try await Shell.run(tmux, ["-L", TmuxSessions.socketName(databasePath: store.path), "kill-server"], cwd: workspace.path)
        await service.shutdown()
    }

}
