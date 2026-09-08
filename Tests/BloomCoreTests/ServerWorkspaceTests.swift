import Foundation
import Testing
@testable import BloomCore

@Suite("ServerWorkspace", .scratchDirectory, .tags(.subprocess, .persistence))
struct ServerWorkspaceTests {
    @Test func runScriptsUseServerEnvironmentAndRetryDoesNotLaunchTwice() async throws {
        guard let tmux = Shell.which("tmux") else { return }
        let repo = try await TempRepo()
        try repo.write(".bloom/settings.toml", """
        [scripts.run.verify]
        name = "Verify server"
        command = "printf '%s\\n' \\\"$BLOOM_WORKSPACE_PATH:$BLOOM_PORT\\\" >> run-output.txt"
        """)
        let store = try makeTestStore("run-script")
        let storedRepo = try await store.upsert(Repo(name: "Test", path: repo.path))
        let workspace = try await store.upsert(Workspace(repoID: storedRepo.id, name: "Test", branch: "main", path: repo.path, baseBranch: "main"))
        let runtime = ServerRuntime(store: store)
        let request = ServerRequest(.workspace(workspaceID: workspace.id, action: .runScript(id: "verify")))
        let first = await runtime.respond(to: request)
        guard case .terminalPane(let pane) = first.result else { Issue.record("Script failed: \(first.result)"); await runtime.shutdown(); return }
        let retry = await runtime.respond(to: request)
        if case .terminalPane(let repeated) = retry.result { #expect(pane == repeated) } else { Issue.record("Retry lost its terminal") }
        await waitUntil("run script writes its server environment") { FileManager.default.fileExists(atPath: repo.path + "/run-output.txt") }
        let port = try #require(try await store.workspace(id: workspace.id)?.port)
        #expect(port > 0)
        #expect(try String(contentsOfFile: repo.path + "/run-output.txt", encoding: .utf8) == "\(repo.path):\(port)\n")
        let socket = TmuxSessions.socketName(databasePath: store.path)
        _ = try await Shell.run(tmux, ["-L", socket, "kill-server"], cwd: repo.path)
        await runtime.shutdown()
    }

    @Test func editingChecksTheLoadedRevisionAndPreservesExecutableMode() async throws {
        let repo = try await TempRepo()
        let workspace = Workspace(repoID: .new(), name: "Test", branch: "main", path: repo.path, baseBranch: "main")
        let path = repo.path + "/script.sh"
        try "first\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        let original = try ServerReview.file(workspace: workspace, path: "script.sh")
        let saved = try ServerFileOperations.write(workspace: workspace, path: "script.sh", text: "second\n", revision: original.revision)
        #expect(saved.text == "second\n")
        #expect(saved.revision != original.revision)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o755)
        #expect(throws: ServerFailure.self) {
            _ = try ServerFileOperations.write(workspace: workspace, path: "script.sh", text: "stale\n", revision: original.revision)
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "second\n")
    }

    @Test func binaryTransfersStayInsideTheWorkspace() async throws {
        let repo = try await TempRepo()
        let workspace = Workspace(repoID: .new(), name: "Test", branch: "main", path: repo.path, baseBranch: "main")
        let data = Data([0, 255, 10, 128])
        let path = try ServerFileOperations.upload(workspace: workspace, name: "test.bin", data: data)
        #expect(path.hasPrefix(".bloom/attachments/"))
        let visible = try await Git.check(["ls-files", "--others", "--exclude-standard"], in: repo.path)
        #expect(!visible.stdout.contains("test.bin"))
        #expect(try ServerFileOperations.download(workspace: workspace, path: path).data == data)
        #expect(throws: ServerFailure.self) { _ = try ServerFileOperations.upload(workspace: workspace, name: "../escape", data: data) }
        #expect(throws: ServerFailure.self) { _ = try ServerFileOperations.download(workspace: workspace, path: "../escape") }
        let outside = TestScratch.path("outside.bin")
        try data.write(to: URL(fileURLWithPath: outside))
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/external", withDestinationPath: outside)
        #expect(throws: ServerFailure.self) { _ = try ServerFileOperations.download(workspace: workspace, path: "external") }
    }

    @Test func repeatedCommitRequestCreatesOnlyOneCommit() async throws {
        let repo = try await TempRepo()
        let store = try makeTestStore("workspace-actions")
        let storedRepo = try await store.upsert(Repo(name: "Test", path: repo.path))
        let workspace = try await store.upsert(Workspace(repoID: storedRepo.id, name: "Test", branch: "main", path: repo.path, baseBranch: "main"))
        try "change\n".write(toFile: repo.path + "/changed.txt", atomically: true, encoding: .utf8)
        let runtime = ServerRuntime(store: store)
        let request = ServerRequest(.workspace(workspaceID: workspace.id, action: .commit(message: "Remote change")))
        let first = await runtime.respond(to: request)
        if case .text = first.result {} else { Issue.record("Commit failed") }
        let head = try await Git.check(["rev-parse", "HEAD"], in: repo.path)
        _ = await runtime.respond(to: request)
        #expect(try await Git.check(["rev-parse", "HEAD"], in: repo.path).stdout == head.stdout)
        await runtime.shutdown()
    }

    @Test func terminalConnectsToTheServerOwnedShell() async throws {
        guard let tmux = Shell.which("tmux") else { return }
        let repo = try await TempRepo()
        let store = try makeTestStore("terminal-action")
        let workspace = Workspace(repoID: .new(), name: "Test", branch: "main", path: repo.path, baseBranch: "main")
        let service = ServerTerminalService()
        let result = try await ServerWorkspaceOperations.perform(.terminal(name: "main"), workspace: workspace, store: store, terminals: service)
        guard case .terminal(let terminal) = result else { Issue.record("Missing terminal"); return }
        do {
            let sent = try await Shell.run(tmux, ["-S", terminal.socket, "send-keys", "-t", terminal.session + ":", "printf 'BLOOM_%s\\n' 'TERMINAL_OK'", "Enter"], cwd: repo.path)
            #expect(sent.ok)
            await waitUntil("terminal executes on its owning host") {
                let capture = try? await Shell.run(tmux, ["-S", terminal.socket, "capture-pane", "-p", "-t", terminal.session + ":"], cwd: repo.path)
                return capture?.stdout.contains("BLOOM_TERMINAL_OK") == true
            }
            let launch = try ServerEndpoint.ssh(host: "user@test", executable: "/srv/bloom-server", directory: "/srv/data").terminalLaunch(terminal)
            #expect(launch.arguments.contains("-tt"))
            #expect(launch.arguments.last?.contains(terminal.socket) == true)
        } catch {
            _ = try? await Shell.run(tmux, ["-S", terminal.socket, "kill-server"], cwd: repo.path)
            throw error
        }
        await service.shutdown()
        let remaining = try await Shell.run(tmux, ["-S", terminal.socket, "has-session", "-t", "=" + terminal.session], cwd: repo.path)
        #expect(!remaining.ok, "Stopping the owning server must close its terminal sessions")
    }

    @Test func previewForwardingBindsOnlyLoopbackAndRejectsInvalidPorts() throws {
        let endpoint = ServerEndpoint.ssh(host: "user@test", executable: "/srv/server", directory: "/srv/data", identityFile: "/Users/test/my key")
        let launch = try endpoint.forwardLaunch(remotePort: 8000, localPort: 55000)
        #expect(launch.arguments.contains("127.0.0.1:55000:127.0.0.1:8000"))
        #expect(launch.arguments.contains("ExitOnForwardFailure=yes"))
        #expect(launch.arguments.contains("IdentityAgent=none"))
        #expect(launch.arguments.contains("/Users/test/my key"))
        #expect(throws: ServerFailure.self) { _ = try endpoint.forwardLaunch(remotePort: 0, localPort: 55000) }
        #expect(throws: ServerFailure.self) { _ = try endpoint.forwardLaunch(remotePort: 8000, localPort: 65536) }
    }

    @Test func remoteAnswersPreservePlanModesAndDenialText() {
        #expect(ServerAnswer.approvePlan(mode: .acceptEdits).decision == .approvePlan(mode: .acceptEdits))
        #expect(ServerAnswer.denyWithReason(message: "Use the fixture only", endsTurn: true).decision == .deny(message: "Use the fixture only", endsTurn: true))
    }

    @Test func remoteSelectionCannotResolveToALocalWorkspace() {
        let id = SessionID.new()
        let selection = SidebarSelection.remote(id)
        #expect(selection.workspaceID == nil)
        #expect(selection.remoteSessionID == id)
    }
}
