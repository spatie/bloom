import Foundation
import Testing
@testable import BloomCore

@Suite("Setup output", .tags(.persistence), .scratchDirectory)
struct SetupOutputTests {
    @Test func retriesResetOutputAndRejectLateWritesFromPreviousAttempts() async throws {
        let store = try makeTestStore("setup-attempts")
        let repo = try await store.upsert(Repo(name: "Project", path: "/tmp/project"))
        let workspace = try await store.upsert(Workspace(repoID: repo.id, name: "Workspace", branch: "test",
                                                         path: "/tmp/project/workspace", baseBranch: "main"))
        let first = try await store.beginSetupAttempt(workspaceID: workspace.id)
        try await store.recordSetupOutput(workspaceID: workspace.id, attempt: first, log: "old failure")
        let second = try await store.beginSetupAttempt(workspaceID: workspace.id)
        #expect(try await store.workspace(id: workspace.id)?.setupLog == "")
        try await store.recordSetupOutput(workspaceID: workspace.id, attempt: first, log: "late output")
        try await store.finishSetupAttempt(workspaceID: workspace.id, attempt: first, succeeded: false, log: "old failure")
        #expect(try await store.workspace(id: workspace.id)?.setupState == .running)
        #expect(try await store.workspace(id: workspace.id)?.setupLog == "")
        _ = try await store.update(workspaceID: workspace.id) { $0.name = "Renamed while running" }
        try await store.finishSetupAttempt(workspaceID: workspace.id, attempt: second, succeeded: true, log: "done")
        try await store.recordSetupOutput(workspaceID: workspace.id, attempt: second, log: "late timer flush")
        let completed = try #require(try await store.workspace(id: workspace.id))
        #expect(completed.setupState == .succeeded)
        #expect(completed.setupLog == "done")
        #expect(completed.name == "Renamed while running")
    }

    @Test func noisyScriptsKeepOnlyABoundedTailInMemoryAndInTheStore() async throws {
        let store = try makeTestStore("setup-tail")
        let repo = try await store.upsert(Repo(name: "Project", path: "/tmp/project"))
        let workspace = try await store.upsert(Workspace(repoID: repo.id, name: "Workspace", branch: "test",
                                                         path: "/tmp/project/workspace", baseBranch: "main"))
        let attempt = try await store.beginSetupAttempt(workspaceID: workspace.id)
        let output = SetupOutputBuffer(store: store, workspaceID: workspace.id, attempt: attempt)
        await output.append(String(repeating: "é", count: Workspace.setupLogLimit + 30))
        await output.append("latest output")
        let held = await output.snapshot()
        #expect(held.count == Workspace.setupLogLimit)
        #expect(held.hasSuffix("latest output\n"))
        #expect(try await store.workspace(id: workspace.id)?.setupLog == "")
        await output.flush()
        #expect(try await store.workspace(id: workspace.id)?.setupLog == held)
    }
}
