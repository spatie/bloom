import Foundation
import Testing
@testable import BloomCore

@Suite("Server sidebar", .scratchDirectory, .tags(.git, .persistence, .destructive))
struct ServerSidebarTests {
    private func fixture() async throws -> (TempRepo, Store, Workspace, Session, ServerRuntime) {
        let repo = try await TempRepo()
        try repo.write(".bloom/settings.toml", "[git]\ndelete_branch_on_archive = false\n")
        try await Shell.check("git", ["add", ".bloom/settings.toml"], cwd: repo.path)
        try await Shell.check("git", ["-c", "commit.gpgsign=false", "commit", "-m", "Keep archived branches"], cwd: repo.path)
        let store = try makeTestStore("server-sidebar")
        let manager = WorkspaceManager(store: store)
        let project = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: project, prompt: "Sidebar verification")
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat"))
        return (repo, store, workspace, session, ServerRuntime(store: store, installedAgents: { _ in [.claudeCode, .codex] }))
    }

    @Test func archiveClosesOnlyItsOwnTerminals() async throws {
        guard let tmux = Shell.which("tmux") else { return }
        let (_, store, workspace, _, runtime) = try await fixture()
        let repo = try #require(try await store.repo(id: workspace.repoID))
        let neighbour = try await WorkspaceManager(store: store).createWorkspace(repo: repo, prompt: "Keep this terminal")
        let first = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .terminal(name: "first"))))
        let second = await runtime.respond(to: ServerRequest(.workspace(workspaceID: neighbour.id, action: .terminal(name: "second"))))
        guard case .terminal(let a) = first.result, case .terminal(let b) = second.result else {
            Issue.record("Missing server terminals"); await runtime.shutdown(); return
        }
        let checked = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .archivePreview)))
        guard case .archivePreview(let preview) = checked.result else { Issue.record("Missing archive preview"); await runtime.shutdown(); return }
        let archived = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .archive(confirmation: preview.id))))
        if case .accepted = archived.result {} else { Issue.record("Archive refused: \(archived.result)") }
        let closed = try await Shell.run(tmux, ["-S", a.socket, "has-session", "-t", "=" + a.session], cwd: repo.path)
        let retained = try await Shell.run(tmux, ["-S", b.socket, "has-session", "-t", "=" + b.session], cwd: repo.path)
        #expect(!closed.ok)
        #expect(retained.ok)
        await runtime.shutdown()
    }

    @Test func failingArchiveScriptPreservesTheWorktree() async throws {
        let (_, store, workspace, _, runtime) = try await fixture()
        try "[git]\ndelete_branch_on_archive = false\n[scripts]\narchive = \"exit 7\"\n".write(
            toFile: workspace.path + "/.bloom/settings.toml", atomically: true, encoding: .utf8
        )
        let first = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .archivePreview)))
        guard case .archivePreview(let preview) = first.result else { Issue.record("Missing preview"); return }
        let reply = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .archive(confirmation: preview.id))))
        if case .failure = reply.result {} else { Issue.record("The failed archive script was ignored") }
        #expect(try await store.workspace(id: workspace.id)?.state == .active)
        #expect(FileManager.default.fileExists(atPath: workspace.path))
        let rename = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .rename("Still available"))))
        if case .accepted = rename.result {} else { Issue.record("Failed archive left the workspace locked") }
        await runtime.shutdown()
    }

    @Test func concurrentArchiveRequestsRunCleanupOnlyOnce() async throws {
        let (repo, store, workspace, _, runtime) = try await fixture()
        // Cleanup records outside the worktree, which is removed by a successful archive.
        let script = "[git]\ndelete_branch_on_archive = false\n[scripts]\narchive = \"echo once >> '" + repo.path + "/archive-count'; sleep 0.1\"\n"
        try repo.write(".bloom/settings.local.toml", script)
        let checked = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .archivePreview)))
        guard case .archivePreview(let preview) = checked.result else { Issue.record("Missing preview"); return }
        let operation = ServerOperation.workspace(workspaceID: workspace.id, action: .archive(confirmation: preview.id))
        async let a = runtime.respond(to: ServerRequest(operation))
        async let b = runtime.respond(to: ServerRequest(operation))
        _ = await [a, b]
        #expect(try await store.workspace(id: workspace.id)?.state == .archived)
        #expect(try String(contentsOfFile: repo.path + "/archive-count", encoding: .utf8) == "once\n")
        await runtime.shutdown()
    }

    @Test func metadataWritesChangeOnlyTheirOwnColumns() async throws {
        let (_, store, workspace, _, runtime) = try await fixture()
        for action in [ServerWorkspaceAction.rename("Renamed"), .setPinned(true), .setUnread(true), .setColour(WorkspaceColour.all[0].hex)] {
            let reply = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: action)))
            guard case .accepted = reply.result else { Issue.record("Metadata refused: \(reply.result)"); return }
        }
        let saved = try #require(try await store.workspace(id: workspace.id))
        #expect(saved.name == "Renamed")
        #expect(saved.pinned && saved.unread)
        #expect(saved.colour == WorkspaceColour.all[0].hex)
        #expect(saved.path == workspace.path && saved.branch == workspace.branch)
        let renamed = await runtime.respond(to: ServerRequest(.project(repoID: workspace.repoID, action: .rename("Project name"))))
        guard case .accepted = renamed.result else { Issue.record("Project rename refused"); return }
        #expect(try await store.repo(id: workspace.repoID)?.name == "Project name")
        await runtime.shutdown()
    }

    @Test func changedWorkNeedsANewConfirmationBeforeArchive() async throws {
        let (_, store, workspace, _, runtime) = try await fixture()
        let first = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .archivePreview)))
        guard case .archivePreview(let preview) = first.result else { Issue.record("Missing preview: \(first.result)"); return }
        try "Only copy\n".write(toFile: workspace.path + "/uncommitted.txt", atomically: true, encoding: .utf8)
        let attempt = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .archive(confirmation: preview.id))))
        guard case .archivePreview(let changed) = attempt.result else { Issue.record("Changed work was not checked again"); return }
        #expect(changed.report.untrackedFiles.contains("uncommitted.txt"))
        #expect(changed.request.isDestructive)
        #expect(try await store.workspace(id: workspace.id)?.state == .active)
        #expect(FileManager.default.fileExists(atPath: workspace.path + "/uncommitted.txt"))
        let roundTrip = try JSONDecoder().decode(ServerReply.self, from: JSONEncoder().encode(attempt))
        if case .archivePreview(let decoded) = roundTrip.result { #expect(decoded.report == changed.report) } else { Issue.record("Preview did not round trip") }
        await runtime.shutdown()
    }

    @Test func archiveAndRestoreKeepTheBranchNotesAndConversation() async throws {
        let (repo, store, workspace, session, runtime) = try await fixture()
        try await store.saveNote(workspaceID: workspace.id, body: "Remember this")
        _ = try await store.appendNext(sessionID: session.id, kind: .user, payload: Data("History".utf8))
        let first = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .archivePreview)))
        guard case .archivePreview(let preview) = first.result else { Issue.record("Missing preview"); return }
        let request = ServerRequest(.workspace(workspaceID: workspace.id, action: .archive(confirmation: preview.id)))
        let archived = await runtime.respond(to: request)
        guard case .accepted = archived.result else { Issue.record("Archive refused: \(archived.result)"); return }
        let repeated = await runtime.respond(to: request)
        if case .accepted = repeated.result {} else { Issue.record("Archive retry failed") }
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
        #expect(await Git.branchExists(workspace.branch, in: repo.path))
        #expect(try await store.workspace(id: workspace.id)?.state == .archived)
        let catalogue = await runtime.respond(to: ServerRequest(.catalogue))
        if case .catalogue(let value) = catalogue.result {
            #expect(!value.workspaces.contains { $0.id == workspace.id })
            #expect(value.archivedWorkspaces.contains { $0.id == workspace.id })
        } else { Issue.record("Missing catalogue") }
        let restored = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .restore)))
        guard case .accepted = restored.result else { Issue.record("Restore failed: \(restored.result)"); return }
        let found = try #require(try await store.workspace(id: workspace.id))
        #expect(found.state == .active)
        #expect(FileManager.default.fileExists(atPath: found.path))
        #expect(try await store.note(workspaceID: workspace.id)?.body == "Remember this")
        #expect(try await store.messages(sessionID: session.id).count == 1)
        await runtime.shutdown()
    }

    @Test func forgedConfirmationAndQueuedWorkCannotRemoveAWorktree() async throws {
        let (_, store, workspace, session, runtime) = try await fixture()
        let forged = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .archive(confirmation: UUID()))))
        if case .archivePreview = forged.result {} else { Issue.record("Expected a fresh confirmation") }
        #expect(FileManager.default.fileExists(atPath: workspace.path))
        _ = try await store.enqueueDelivery(Delivery(targetSessionID: session.id, body: "Still to do"))
        let pending = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspace.id, action: .archivePreview)))
        if case .failure(let reason) = pending.result { #expect(reason.contains("queued")) } else { Issue.record("Pending work was ignored") }
        #expect(try await store.workspace(id: workspace.id)?.state == .active)
        await runtime.shutdown()
    }
}
