import Foundation
import Testing
@testable import BloomCore

/// Deleting an archived workspace and removing a project on a Bloom Server.
///
/// The server computes every confirmation and checks it again, so these drive the runtime the way
/// a client does: ask for the preview, hand back its id, and read what is left.
@Suite("Server permanent removal", .scratchDirectory, .tags(.subprocess, .persistence))
struct ServerRemovalTests {
    @Test("a delete needs protocol 16, an archived workspace and the server's own confirmation")
    func deletesAnArchivedWorkspace() async throws {
        let (store, runtime, workspace) = try await fixture()
        defer { Task { await runtime.shutdown() } }

        let old = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .deletePreview), version: 15))
        guard case .failure(let refusal) = old.result else { throw ServerFailure("Protocol 15 was allowed to delete") }
        #expect(refusal.contains("protocol 16"))

        let active = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .deletePreview)))
        guard case .failure(let notArchived) = active.result else { throw ServerFailure("An active workspace offered a delete") }
        #expect(notArchived.contains("Archive it first"))

        try await archive(workspace, runtime: runtime)
        let forged = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .delete(confirmation: UUID()))))
        guard case .removalPreview(let preview) = forged.result else { throw ServerFailure("A made-up confirmation was not answered with a preview") }
        #expect(try await store.workspace(id: workspace.id) != nil)
        #expect(preview.title.contains(workspace.name))
        #expect(preview.message.contains("compacts its database"))
        #expect(preview.blocker == nil)

        let deleted = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .delete(confirmation: preview.id))))
        guard case .accepted = deleted.result else { throw ServerFailure("The confirmed delete was refused: \(deleted.result)") }
        #expect(try await store.workspace(id: workspace.id) == nil)
    }

    @Test("a stale confirmation is sent back as a fresh preview and deletes nothing")
    func staleConfirmation() async throws {
        let (store, runtime, workspace) = try await fixture()
        defer { Task { await runtime.shutdown() } }
        try await archive(workspace, runtime: runtime)
        let first = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .deletePreview)))
        guard case .removalPreview(let preview) = first.result else { throw ServerFailure("No preview") }
        try await store.saveNote(workspaceID: workspace.id, body: "Written after the preview")
        let reply = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .delete(confirmation: preview.id))))
        guard case .removalPreview(let fresh) = reply.result else { throw ServerFailure("A changed workspace was deleted on an old confirmation") }
        #expect(fresh.id != preview.id)
        #expect(fresh.message.contains("a workspace note"))
        #expect(try await store.workspace(id: workspace.id) != nil)
    }

    @Test("removing a project archives its clean workspaces first and keeps a repository Bloom did not create")
    func removesAProject() async throws {
        let (store, runtime, workspace) = try await fixture()
        defer { Task { await runtime.shutdown() } }
        let repoID = workspace.repoID
        let repoPath = try #require(try await store.repo(id: repoID)?.path)

        let asked = await runtime.respond(to: ServerRequest(.project(repoID: repoID, action: .removalPreview)))
        guard case .removalPreview(let preview) = asked.result else { throw ServerFailure("No project preview: \(asked.result)") }
        #expect(preview.blocker == nil)
        #expect(preview.confirmLabel == "Archive and Remove")
        #expect(preview.message.contains("Bloom did not create it"))

        let removed = await runtime.respond(to: ServerRequest(.project(repoID: repoID, action: .remove(confirmation: preview.id))))
        guard case .accepted = removed.result else { throw ServerFailure("The confirmed removal was refused: \(removed.result)") }
        #expect(try await store.repo(id: repoID) == nil)
        #expect(try await store.workspace(id: workspace.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
        #expect(FileManager.default.fileExists(atPath: repoPath))
    }

    @Test("a workspace with work only in its worktree blocks the removal")
    func blockedByUnprotectedWork() async throws {
        let (store, runtime, workspace) = try await fixture()
        defer { Task { await runtime.shutdown() } }
        try TempRepo(existing: workspace.path).write("notes.txt", "Not committed anywhere")
        let asked = await runtime.respond(to: ServerRequest(.project(repoID: workspace.repoID, action: .removalPreview)))
        guard case .removalPreview(let preview) = asked.result else { throw ServerFailure("No project preview") }
        let blocker = try #require(preview.blocker)
        #expect(blocker.contains(workspace.name))
        let refused = await runtime.respond(to: ServerRequest(.project(repoID: workspace.repoID, action: .remove(confirmation: preview.id))))
        guard case .failure = refused.result else { throw ServerFailure("A blocked removal went ahead") }
        #expect(try await store.workspace(id: workspace.id)?.state == .active)
    }

    @Test("only a directory shaped like Bloom's own clone counts as managed")
    func managedClone() throws {
        let data = TestScratch.unique("data")
        let clone = data + "/repositories/bloom-0123456789ab"
        try FileManager.default.createDirectory(atPath: clone, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: data + "/repositories/bloom", withIntermediateDirectories: true)
        #expect(ServerRemoval.isManagedClone(clone, dataDirectory: data))
        #expect(!ServerRemoval.isManagedClone(data + "/repositories/bloom", dataDirectory: data))
        #expect(!ServerRemoval.isManagedClone(data + "/repositories/missing-0123456789ab", dataDirectory: data))
        #expect(!ServerRemoval.isManagedClone(clone + "/../bloom-0123456789ab/nested", dataDirectory: data))
    }

    @Test("a thread a surviving chat holds is kept out of the delete")
    func threadsOutside() async throws {
        let store = try makeTestStore("threads")
        let repo = try await store.upsert(Repo(name: "Project", path: "/srv/project"))
        let archived = try await store.upsert(Workspace(repoID: repo.id, name: "old", branch: "old", path: "/srv/old", baseBranch: "main"))
        let live = try await store.upsert(Workspace(repoID: repo.id, name: "new", branch: "new", path: "/srv/new", baseBranch: "main"))
        _ = try await store.upsert(Session(workspaceID: archived.id, title: "Old", agentSessionID: "shared"))
        _ = try await store.upsert(Session(workspaceID: archived.id, title: "Codex", agentSessionID: "thread", agentKind: .codex))
        _ = try await store.upsert(Session(workspaceID: live.id, title: "Carried on", agentSessionID: "shared"))
        #expect(Set(try await store.agentThreads(workspaceID: archived.id)) == [AgentThread(kind: .claudeCode, agentSessionID: "shared"), AgentThread(kind: .codex, agentSessionID: "thread")])
        #expect(try await store.agentThreadIDs(outside: [archived.id]) == ["shared"])
    }

    @Test("the project copy says what is archived, what is deleted and why a repository stays")
    func projectCopy() {
        let facts = ServerProjectRemovalFacts(projectName: "Bloom", activeCount: 2, deletion: ArchiveDeletion([], host: "the server"),
                                              clone: .deleted(path: "/home/bloom/bloom/data/repositories/bloom-0123456789ab", bytes: 2_000_000), blockers: [])
        let preview = ServerRemovalCopy.project(facts)
        #expect(preview.message.contains("Its 2 active workspaces are archived first"))
        #expect(preview.message.contains("The repository clone Bloom made at /home/bloom/bloom/data/repositories/bloom-0123456789ab"))
        #expect(preview.confirmLabel == "Archive and Remove")
        var blocked = facts
        blocked.blockers = ["\u{201C}sea\u{201D} holds work that exists nowhere else."]
        #expect(ServerRemovalCopy.project(blocked).blocker?.contains("Archive it from the sidebar") == true)
    }

    private func fixture() async throws -> (Store, ServerRuntime, Workspace) {
        let repo = try await TempRepo()
        try repo.write(".bloom/settings.toml", "[git]\ndelete_branch_on_archive = false\n")
        try await repo.commit("Keep archived branches")
        let store = try makeTestStore("removal")
        let manager = WorkspaceManager(store: store)
        let project = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: project, prompt: "Removal fixture")
        let runtime = ServerRuntime(store: store, authentication: { agent, _, _ in .init(agent: agent, state: .unknown) },
                                    installedAgents: { _ in [.claudeCode] })
        return (store, runtime, workspace)
    }

    private func archive(_ workspace: Workspace, runtime: ServerRuntime) async throws {
        let checked = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .archivePreview)))
        guard case .archivePreview(let preview) = checked.result else { throw ServerFailure("No archive preview: \(checked.result)") }
        let archived = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .archive(confirmation: preview.id))))
        guard case .accepted = archived.result else { throw ServerFailure("Archive refused: \(archived.result)") }
    }
}
