import Testing
import Foundation
@testable import BatonCore

@Suite("Store", .tags(.persistence), .scratchDirectory)
struct StoreTests {
    @Test("round-trips a repo")
    func roundTripsRepo() async throws {
        let store = try makeTestStore("store")
        let repo = Repo(name: "there-there", path: "/tmp/there-there", defaultBranch: "main")
        try await store.upsert(repo)

        let loaded = try await store.repos()
        #expect(loaded.count == 1)
        #expect(loaded[0].name == "there-there")
        #expect(loaded[0].defaultBranch == "main")
        #expect(try await store.repo(path: "/tmp/there-there")?.id == repo.id)
    }

    @Test("updates a repo on conflicting id")
    func updatesRepo() async throws {
        let store = try makeTestStore("store")
        var repo = Repo(name: "old", path: "/tmp/x")
        try await store.upsert(repo)
        repo.name = "new"
        try await store.upsert(repo)

        #expect(try await store.repos().count == 1)
        #expect(try await store.repos()[0].name == "new")
    }

    @Test("cascades workspace deletion from its repo")
    func cascadesDelete() async throws {
        let store = try makeTestStore("store")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/tmp/r-w", baseBranch: "main"
        ))
        #expect(try await store.workspaces().count == 1)

        try await store.deleteRepo(id: repo.id)
        #expect(try await store.workspaces().isEmpty)
    }

    @Test("hides archived workspaces unless asked")
    func hidesArchived() async throws {
        let store = try makeTestStore("store")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        var workspace = Workspace(repoID: repo.id, name: "w", branch: "b", path: "/p", baseBranch: "main")
        try await store.upsert(workspace)
        workspace.state = .archived
        workspace.archivedAt = Date()
        try await store.upsert(workspace)

        #expect(try await store.workspaces().isEmpty)
        #expect(try await store.workspaces(includeArchived: true).count == 1)
        #expect(try await store.workspace(id: workspace.id)?.archivedAt != nil)
    }

    @Test("appends messages with increasing sequence numbers")
    func appendsMessages() async throws {
        let store = try makeTestStore("store")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/p", baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id))

        for index in 0..<5 {
            let seq = try await store.nextSeq(sessionID: session.id)
            #expect(seq == index)
            try await store.append(Message(
                sessionID: session.id, seq: seq, kind: .assistantText,
                payload: Data("body \(index)".utf8)
            ))
        }

        let messages = try await store.messages(sessionID: session.id)
        #expect(messages.count == 5)
        #expect(messages.map(\.seq) == [0, 1, 2, 3, 4])
        #expect(String(decoding: messages[3].payload, as: UTF8.self) == "body 3")
        #expect(try await store.messages(sessionID: session.id, afterSeq: 2).count == 2)
    }

    @Test("finds a tool use row by its reference id")
    func findsByRefID() async throws {
        let store = try makeTestStore("store")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/p", baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id))

        try await store.append(Message(
            sessionID: session.id, seq: 0, kind: .toolUse,
            payload: Data("{}".utf8), refID: "toolu_123"
        ))

        let found = try await store.message(sessionID: session.id, refID: "toolu_123")
        #expect(found?.kind == .toolUse)
        #expect(try await store.message(sessionID: session.id, refID: "nope") == nil)
    }

    @Test("stores and clears drafts")
    func storesDrafts() async throws {
        let store = try makeTestStore("store")
        try await store.saveDraft(sessionID: "s1", body: "hello")
        #expect(try await store.draft(sessionID: "s1") == "hello")
        try await store.saveDraft(sessionID: "s1", body: "")
        #expect(try await store.draft(sessionID: "s1") == "")
    }

    @Test("resets sessions that were running when the app died")
    func resetsRunningSessions() async throws {
        let store = try makeTestStore("store")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/p", baseBranch: "main"
        ))
        var session = Session(workspaceID: workspace.id)
        session.state = .running
        try await store.upsert(session)

        try await store.resetRunningSessions()
        #expect(try await store.session(id: session.id)?.state == .idle)
    }

    @Test("survives a reopen")
    func survivesReopen() async throws {
        let path = TestScratch.unique("baton-persist") + ".sqlite"
        let first = try Store(path: path)
        try await first.upsert(Repo(name: "persisted", path: "/tmp/p"))

        let second = try Store(path: path)
        #expect(try await second.repos().map(\.name) == ["persisted"])
    }
}
