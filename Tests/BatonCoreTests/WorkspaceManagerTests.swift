import Testing
import Foundation
@testable import BatonCore

@Suite("WorkspaceManager", .tags(.git), .scratchDirectory)
struct WorkspaceManagerTests {
    @Test("registers a repository once, and finds its default branch")
    func registersRepository() async throws {
        let repo = try await TempRepo(defaultBranch: "main")
        defer { repo.cleanUp() }
        let manager = WorkspaceManager(store: try makeTestStore("wm"))

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
        let manager = WorkspaceManager(store: try makeTestStore("wm"))
        let plain = TestScratch.unique("baton-plain")
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)

        let error = await #expect(throws: WorkspaceError.self) {
            try await manager.addRepository(at: plain)
        }
        guard case .notARepository? = error else {
            Issue.record("expected notARepository, got \(String(describing: error))")
            return
        }
    }

    @Test("creates a worktree, a branch and a persisted workspace from a prompt")
    func createsWorkspace() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let store = try makeTestStore("wm")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)

        let workspace = try await manager.createWorkspace(
            repo: registered,
            prompt: "Stop the silent field clear when a value is missing"
        )

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
        let manager = WorkspaceManager(store: try makeTestStore("wm"))
        let registered = try await manager.addRepository(at: repo.path)

        let first = try await manager.createWorkspace(repo: registered, prompt: "Fix the flaky test")
        let second = try await manager.createWorkspace(repo: registered, prompt: "Fix the flaky test")

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

        let manager = WorkspaceManager(store: try makeTestStore("wm"))
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Copy env files")

        let worktree = TempRepo(existing: workspace.path)
        #expect(worktree.read(".env") == "APP_ENV=local\n")
        #expect(worktree.read(".env.testing") == "APP_ENV=testing\n")
        // The default pattern is .env* only, so nothing else should have travelled.
        #expect(worktree.exists("secret.key") == false)
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

        let manager = WorkspaceManager(store: try makeTestStore("wm"))
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Use the settings file")

        #expect(workspace.branch == "freek/use-settings-file")
        // A slash in the branch must not create a nested directory.
        #expect(workspace.path.contains("freek/use") == false)
        #expect(workspace.path.hasSuffix("freek-use-settings-file"))

        let worktree = TempRepo(existing: workspace.path)
        #expect(worktree.exists("secret.key"))
        #expect(worktree.exists(".env"))
    }

    @Test("runs the setup script with the workspace environment exported", .tags(.subprocess))
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

        let store = try makeTestStore("wm")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Run setup")

        #expect(workspace.setupState == .pending)

        let collector = LineCollector()
        let succeeded = await manager.runSetup(
            workspace: workspace, repo: registered, port: 3_100
        ) { collector.append($0) }

        #expect(succeeded)
        let output = collector.joined
        #expect(output.contains("name=run-setup"))
        // The temp directory reaches the child through /private/var, so compare the last component.
        #expect(output.contains("root="))
        #expect(output.contains(URL(fileURLWithPath: repo.path).lastPathComponent))
        #expect(output.contains("port=3100"))
        #expect(output.contains("local=1"))

        let worktree = TempRepo(existing: workspace.path)
        #expect(worktree.exists("setup-ran.txt"))
        #expect(try await store.workspace(id: workspace.id)?.setupState == .succeeded)
    }

    @Test("records a failing setup script rather than pretending it worked", .tags(.subprocess))
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

        let store = try makeTestStore("wm")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Fail setup")

        let succeeded = await manager.runSetup(workspace: workspace, repo: registered, port: 0) { _ in }
        #expect(succeeded == false)

        let stored = try await store.workspace(id: workspace.id)
        #expect(stored?.setupState == .failed)
        #expect(stored?.setupLog.contains("about to fail") == true)
    }

    @Test(
        "a finishing setup run does not undo edits made while it ran",
        .tags(.subprocess), .timeLimit(.minutes(1))
    )
    func setupDoesNotClobberConcurrentEdits() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        // The script blocks until the test says go, so the window in which the row is `running`
        // is controlled rather than raced against a sleep.
        try repo.write(".conductor/settings.toml", """
        [scripts]
        setup = '''
        for _ in $(seq 1 600); do
          [ -f "$BATON_WORKSPACE_PATH/go" ] && exit 0
          sleep 0.05
        done
        exit 1
        '''
        """)

        let store = try makeTestStore("wm")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Slow setup")

        let run = Task {
            await manager.runSetup(workspace: workspace, repo: registered, port: 0) { _ in }
        }
        await waitUntil("the setup run has marked the workspace running") {
            (try? await store.workspace(id: workspace.id))??.setupState == .running
        }

        try await store.upsert(workspace.with {
            $0.name = "renamed while setup ran"
            $0.pinned = true
        })

        let worktree = TempRepo(existing: workspace.path)
        try worktree.write("go", "")

        #expect(await run.value)

        let stored = try #require(try await store.workspace(id: workspace.id))
        #expect(stored.setupState == .succeeded)
        #expect(stored.name == "renamed while setup ran")
        #expect(stored.pinned)
    }

    @Test("archiving removes the worktree and runs the archive script", .tags(.destructive))
    func archivesWorkspace() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        try repo.write(".conductor/settings.toml", """
        [scripts]
        archive = 'echo archived > "$BATON_ROOT_PATH/archive-marker.txt"'
        """)

        let store = try makeTestStore("wm")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Archive me")

        try await manager.archive(workspace: workspace, repo: registered)

        #expect(FileManager.default.fileExists(atPath: workspace.path) == false)
        #expect(repo.exists("archive-marker.txt"))
        #expect(try await store.workspace(id: workspace.id)?.state == .archived)
        #expect(try await store.workspaces().isEmpty)
        // The branch survives by default, so work is never silently destroyed.
        #expect(await Git.branchExists(workspace.branch, in: repo.path))
    }

    @Test("archiving can delete the branch when asked", .tags(.destructive))
    func archivesAndDeletesBranch() async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let manager = WorkspaceManager(store: try makeTestStore("wm"))
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Delete my branch")

        try await manager.archive(workspace: workspace, repo: registered, deleteBranch: true)
        #expect(await Git.branchExists(workspace.branch, in: repo.path) == false)
    }

    @Test("matches copy patterns the way a shell glob would", arguments: [
        (".env", ".env*", true),
        (".env.local", ".env*", true),
        ("env", ".env*", false),
        ("secret.key", "secret.key", true),
        ("secret.key2", "secret.key", false),
        ("a.txt", "?.txt", true),
        ("ab.txt", "?.txt", false),
    ])
    func matchesGlobs(name: String, pattern: String, expected: Bool) throws {
        let manager = WorkspaceManager(store: try makeTestStore("wm"))
        #expect(manager.matches(name, pattern: pattern) == expected)
    }
}
