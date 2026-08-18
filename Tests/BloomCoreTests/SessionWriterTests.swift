import Testing
import Foundation
@testable import BloomCore

/// A session row has two writers. `AgentRunner` owns the agent session id, the state and the
/// counters. The UI owns the title and the composer's pickers. The first version of Bloom had
/// the UI write the whole struct, which silently dropped the agent session id and broke resume
/// without any visible error. These tests exist so that cannot come back.
@Suite("Session writers", .tags(.persistence), .scratchDirectory)
struct SessionWriterTests {
    private func makeSession() async throws -> (Store, Session) {
        let store = try makeTestStore("sw")
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r-\(UUID().uuidString)"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/p", baseBranch: "main"
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id))
        return (store, session)
    }

    @Test("a preference write does not disturb the fields the runner owns")
    func preferencesDoNotClobberRunnerFields() async throws {
        let (store, session) = try await makeSession()

        // The runner binds the session and records a finished turn.
        _ = try await store.upsert(session.with {
            $0.agentSessionID = "f93932c9-cf0b-40d8-881c-ac75db3f8740"
            $0.state = .running
            $0.inputTokens = 120
            $0.outputTokens = 340
            $0.costUSD = 0.42
            $0.contextTokens = 51_000
        })

        // The UI, holding a copy read before any of that, changes a picker.
        try await store.updateSessionPreferences(
            id: session.id, model: "sonnet", effort: "low", permissionMode: .plan
        )

        let stored = try #require(try await store.session(id: session.id))
        #expect(stored.model == "sonnet")
        #expect(stored.effort == "low")
        #expect(stored.permissionMode == .plan)

        #expect(stored.agentSessionID == "f93932c9-cf0b-40d8-881c-ac75db3f8740")
        #expect(stored.state == .running)
        #expect(stored.inputTokens == 120)
        #expect(stored.outputTokens == 340)
        #expect(stored.costUSD == 0.42)
        #expect(stored.contextTokens == 51_000)
    }

    @Test("a nil argument leaves that column alone")
    func nilArgumentsAreNoOps() async throws {
        let (store, session) = try await makeSession()
        try await store.updateSessionPreferences(id: session.id, title: "Renamed")

        let stored = try #require(try await store.session(id: session.id))
        #expect(stored.title == "Renamed")
        #expect(stored.model == session.model)
        #expect(stored.effort == session.effort)
        #expect(stored.permissionMode == session.permissionMode)
    }

    @Test("marking read touches only the read cursor")
    func lastReadSeqIsIsolated() async throws {
        let (store, session) = try await makeSession()
        _ = try await store.upsert(session.with {
            $0.agentSessionID = "abc"
            $0.outputTokens = 99
        })

        try await store.updateLastReadSeq(sessionID: session.id, seq: 42)

        let stored = try #require(try await store.session(id: session.id))
        #expect(stored.lastReadSeq == 42)
        #expect(stored.agentSessionID == "abc")
        #expect(stored.outputTokens == 99)
    }

    @Test("interleaving both writers keeps each one's fields")
    func interleavedWritersBothSurvive() async throws {
        let (store, session) = try await makeSession()

        for step in 0..<20 {
            // The runner writes a whole row, as it legitimately does.
            let current = try #require(try await store.session(id: session.id))
            _ = try await store.upsert(current.with {
                $0.agentSessionID = "agent-\(step)"
                $0.outputTokens += 10
                $0.state = step.isMultiple(of: 2) ? .running : .idle
            })
            // The UI writes a preference from a copy that is now stale.
            try await store.updateSessionPreferences(id: session.id, title: "Turn \(step)")
        }

        let stored = try #require(try await store.session(id: session.id))
        #expect(stored.title == "Turn 19")
        #expect(stored.agentSessionID == "agent-19")
        #expect(stored.outputTokens == 200)
    }
}
