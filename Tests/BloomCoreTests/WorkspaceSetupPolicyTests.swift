import Foundation
import Testing
@testable import BloomCore

@Suite("Workspace setup choice", .tags(.git), .scratchDirectory)
struct WorkspaceSetupPolicyTests {
    @Test("only a configured, requested script starts pending")
    func initialStates() {
        for policy in [WorkspaceSetupPolicy.deferred, .run, .skip] {
            #expect(policy.initialState(script: nil) == .skipped)
            #expect(policy.initialState(script: " \n ") == .skipped)
            #expect(policy.initialState(script: "echo setup") == (policy == .skip ? .skipped : .pending))
        }
    }

    @Test("skip applies to new and existing branches, with or without a chat",
          arguments: [false, true], [false, true])
    func skipsOnlyThisCreation(existingBranch: Bool, opensSession: Bool) async throws {
        let repo = try await TempRepo()
        defer { repo.cleanUp() }
        let store = try makeTestStore("skip-setup")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        try repo.write(".conductor/settings.toml", """
        files_to_copy = ["local.txt"]
        [scripts]
        setup = "echo installed > installed.txt"
        """)
        try repo.write("local.txt", "keep copied files")
        if existingBranch {
            try await Shell.check("git", ["branch", "existing"], cwd: repo.path)
        }

        let started = try await manager.start(WorkspaceStartRequest(
            repo: registered, prompt: "Skip setup", origin: .user,
            checkout: existingBranch ? .branch(ExistingBranch(name: "existing", isLocal: true)) : nil,
            opensSession: opensSession, setupPolicy: .skip
        ))

        #expect(started.workspace.setupState == .skipped)
        #expect(started.setupSucceeded == nil)
        #expect((started.session != nil) == opensSession)
        let stored = try #require(try await store.workspace(id: started.workspace.id))
        #expect(stored.setupState == .skipped)
        #expect(!FileManager.default.fileExists(atPath: started.workspace.path + "/installed.txt"))
        #expect(FileManager.default.fileExists(atPath: started.workspace.path + "/local.txt"))
        #expect(SettingsLoader.load(repo: repo.path).setupScript == "echo installed > installed.txt")

        // The next ordinary create must not inherit this window's opt-out.
        let next = try await manager.start(WorkspaceStartRequest(
            repo: registered, prompt: "Normal setup", origin: .user
        ))
        #expect(next.workspace.setupState == .pending)

        // Skipping automatic setup is not a permanent ban on running it explicitly.
        let succeeded = await manager.runSetup(workspace: stored, repo: registered, port: 0) { _ in }
        #expect(succeeded)
        #expect(FileManager.default.fileExists(atPath: stored.path + "/installed.txt"))
        let afterManualRun = try #require(try await store.workspace(id: stored.id))
        #expect(afterManualRun.setupState == .succeeded)
    }
}
