import Testing
import Foundation
@testable import BatonCore

@Suite("WorkspaceManager")
struct WorkspaceManagerTests {
    private func makeStore() throws -> Store {
        try Store(path: NSTemporaryDirectory() + "baton-wm-\(UUID().uuidString).sqlite")
    }

    @Test("registers a repository once, and finds its default branch")
    func registersRepository() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        let manager = WorkspaceManager(store: try makeStore())

        let added = try await manager.addRepository(at: repo.path)
        #expect(added.defaultBranch == "main")
        #expect(added.accent == Accent.all[0])

        // Adding the same path again returns the existing row rather than a duplicate.
        let again = try await manager.addRepository(at: repo.path)
        #expect(again.id == added.id)
        #expect(try await manager.store.repos().count == 1)
    }

    @Test("refuses a folder that is not a repository")
    func refusesNonRepository() async throws {
        let manager = WorkspaceManager(store: try makeStore())
        let plain = NSTemporaryDirectory() + "baton-plain-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: plain) }

        await #expect(throws: WorkspaceError.self) {
            try await manager.addRepository(at: plain)
        }
    }

    @Test("creates a worktree, a branch and a persisted workspace from a prompt")
    func createsWorkspace() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let store = try makeStore()
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)

        let workspace = try await manager.createWorkspace(
            repo: registered,
            prompt: "Stop the silent field clear when a value is missing"
        )
        defer { Task { try? await Git.removeWorktree(repo: repo.path, path: workspace.path) } }

        #expect(workspace.branch == "stop-silent-field-clear-when")
        #expect(workspace.name == "Stop the silent field clear when a value is missing")
        #expect(workspace.baseBranch == "main")
        #expect(FileManager.default.fileExists(atPath: workspace.path + "/README.md"))

        let worktrees = try await Git.worktrees(of: repo.path)
        #expect(worktrees.contains { $0.branch == workspace.branch })

        #expect(try await store.workspaces().map(\.id) == [workspace.id])
    }

    @Test("does not collide when two workspaces derive the same branch name")
    func avoidsBranchCollisions() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let manager = WorkspaceManager(store: try makeStore())
        let registered = try await manager.addRepository(at: repo.path)

        let first = try await manager.createWorkspace(repo: registered, prompt: "Fix the flaky test")
        let second = try await manager.createWorkspace(repo: registered, prompt: "Fix the flaky test")
        defer {
            Task {
                try? await Git.removeWorktree(repo: repo.path, path: first.path)
                try? await Git.removeWorktree(repo: repo.path, path: second.path)
            }
        }

        #expect(first.branch == "fix-flaky-test")
        #expect(second.branch == "fix-flaky-test-2")
        #expect(first.path != second.path)
    }

    @Test("copies the configured files into a new worktree")
    func copiesFiles() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        try repo.write(".env", "APP_ENV=local\n")
        try repo.write(".env.testing", "APP_ENV=testing\n")
        try repo.write("secret.key", "shh\n")
        // .env files are deliberately not committed, which is exactly why they must be copied.

        let manager = WorkspaceManager(store: try makeStore())
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Copy env files")
        defer { Task { try? await Git.removeWorktree(repo: repo.path, path: workspace.path) } }

        let worktree = TempRepo(existing: workspace.path)
        #expect(worktree.read(".env") == "APP_ENV=local\n")
        #expect(worktree.read(".env.testing") == "APP_ENV=testing\n")
        // The default pattern is .env* only, so nothing else should have travelled.
        #expect(!worktree.exists("secret.key"))
    }

    @Test("honours a repo's settings file for the branch prefix and copied files")
    func honoursRepoSettings() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        // files_to_copy sits at the root, so it has to come before any table header.
        try repo.write(".conductor/settings.toml", """
        files_to_copy = [".env*", "secret.key"]

        [git]
        branch_prefix = "freek"
        """)
        try repo.write("secret.key", "shh\n")
        try repo.write(".env", "x\n")

        let manager = WorkspaceManager(store: try makeStore())
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Use the settings file")
        defer { Task { try? await Git.removeWorktree(repo: repo.path, path: workspace.path) } }

        #expect(workspace.branch == "freek/use-settings-file")
        // A slash in the branch must not create a nested directory.
        #expect(!workspace.path.contains("freek/use"))

        let worktree = TempRepo(existing: workspace.path)
        #expect(worktree.exists("secret.key"))
        #expect(worktree.exists(".env"))
    }

    @Test("runs the setup script with the workspace environment exported")
    func runsSetupScript() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }

        try repo.write(".conductor/settings.toml", """
        [scripts]
        setup = '''
        echo "name=$CONDUCTOR_WORKSPACE_NAME"
        echo "root=$BATON_ROOT_PATH"
        echo "port=$BATON_PORT"
        echo "local=$CONDUCTOR_IS_LOCAL"
        touch setup-ran.txt
        '''
        """)

        let store = try makeStore()
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Run setup")
        defer { Task { try? await Git.removeWorktree(repo: repo.path, path: workspace.path) } }

        #expect(workspace.setupState == .pending)

        let collector = LineCollector()
        let succeeded = await manager.runSetup(
            workspace: workspace, repo: registered, port: 3_100
        ) { collector.append($0) }

        #expect(succeeded)
        let output = collector.joined
        #expect(output.contains("name=run-setup"))
        // The temp directory reaches the child through /private/var, so compare the last component.
        #expect(output.contains("root=") && output.contains(URL(fileURLWithPath: repo.path).lastPathComponent))
        #expect(output.contains("port=3100"))
        #expect(output.contains("local=1"))

        let worktree = TempRepo(existing: workspace.path)
        #expect(worktree.exists("setup-ran.txt"))
        #expect(try await store.workspace(id: workspace.id)?.setupState == .succeeded)
    }

    @Test("records a failing setup script rather than pretending it worked")
    func recordsFailingSetup() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write(".conductor/settings.toml", """
        [scripts]
        setup = '''
        echo "about to fail"
        exit 7
        '''
        """)

        let store = try makeStore()
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Fail setup")
        defer { Task { try? await Git.removeWorktree(repo: repo.path, path: workspace.path) } }

        let succeeded = await manager.runSetup(workspace: workspace, repo: registered, port: 0) { _ in }
        #expect(!succeeded)

        let stored = try await store.workspace(id: workspace.id)
        #expect(stored?.setupState == .failed)
        #expect(stored?.setupLog.contains("about to fail") == true)
    }

    @Test("archiving removes the worktree and runs the archive script")
    func archivesWorkspace() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write(".conductor/settings.toml", """
        [scripts]
        archive = 'echo archived > "$BATON_ROOT_PATH/archive-marker.txt"'
        """)

        let store = try makeStore()
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Archive me")

        try await manager.archive(workspace: workspace, repo: registered)

        #expect(!FileManager.default.fileExists(atPath: workspace.path))
        #expect(repo.exists("archive-marker.txt"))
        #expect(try await store.workspace(id: workspace.id)?.state == .archived)
        #expect(try await store.workspaces().isEmpty)
        // The branch survives by default, so work is never silently destroyed.
        #expect(await Git.branchExists(workspace.branch, in: repo.path))
    }

    @Test("archiving can delete the branch when asked")
    func archivesAndDeletesBranch() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let manager = WorkspaceManager(store: try makeStore())
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Delete my branch")

        try await manager.archive(workspace: workspace, repo: registered, deleteBranch: true)
        #expect(await !Git.branchExists(workspace.branch, in: repo.path))
    }

    @Test("matches copy patterns the way a shell glob would")
    func matchesGlobs() throws {
        let manager = WorkspaceManager(store: try makeStore())
        #expect(manager.matches(".env", pattern: ".env*"))
        #expect(manager.matches(".env.local", pattern: ".env*"))
        #expect(!manager.matches("env", pattern: ".env*"))
        #expect(manager.matches("secret.key", pattern: "secret.key"))
        #expect(!manager.matches("secret.key2", pattern: "secret.key"))
        #expect(manager.matches("a.txt", pattern: "?.txt"))
    }

    @Test("allocates a free port and does not hand out the same one twice")
    func allocatesPorts() {
        let first = PortAllocator.allocate(taken: [])
        let second = PortAllocator.allocate(taken: [first])
        #expect(first >= 3_100)
        #expect(second != first)
        #expect((second - first) % 10 == 0)
    }
}

/// Collects streamed script output from a `@Sendable` callback.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock(); lines.append(line); lock.unlock()
    }

    var joined: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}
