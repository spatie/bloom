import Testing
import Foundation
@testable import BloomCore

// MARK: - Codex persistence failures

/// A scripted server for the runner under test, kept local because the fixtures in
/// `CodexRunnerTests` are private to that file on purpose.
private func scriptedBox() -> ProcessBox {
    let box = ProcessBox()
    let threadStartReply = JSONValue.object([
        "thread": .object(["id": .string("01a02144-3b7e-7233-97f2-73ebd5105085")]),
        "model": .string("gpt-5.6-sol"),
    ])
    box.reply(to: "thread/start", with: threadStartReply)
    box.reply(to: "thread/resume", with: threadStartReply)
    box.reply(to: "turn/start", with: .object([
        "turn": .object([
            "id": .string("01a02144-3bab-7fe3-a92c-6eec594d84fd"),
            "status": .string("inProgress"),
            "items": .array([]),
        ]),
    ]))
    return box
}

@Suite("CodexRunner persistence failures", .tags(.persistence), .scratchDirectory, .timeLimit(.minutes(1)))
struct CodexRunnerPersistenceFailureTests {
    /// The Claude Code runner has surfaced a refused write as an `.error` event since a `try?`
    /// swallowed a whole transcript; the Codex runner counted the failure and told nobody looking
    /// at the window. This pins that both backends now say it out loud.
    @Test("surfaces a failed write instead of pretending the row landed")
    func surfacesFailedAppend() async throws {
        let store = try makeTestStore("codex-persistence")
        // A session that was never inserted: the foreign key on messages refuses every row.
        let session = Session(workspaceID: WorkspaceID("no-such-workspace"))
        let box = scriptedBox()
        let runner = CodexRunner(
            workspacePath: "/tmp/w",
            session: session,
            store: store,
            makeClient: { configuration in
                CodexClient(configuration: configuration, makeProcess: box.factory)
            }
        )

        let events = runner.events
        try await runner.send("hello")

        // Bounded, so a regression fails in seconds rather than hanging on a stream nothing
        // will ever yield into.
        let first = await withTaskGroup(of: AgentEvent?.self) { group in
            group.addTask {
                for await event in events { return event }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let winner = await group.next() ?? nil
            group.cancelAll()
            return winner
        }
        guard case .error(let failure) = first else {
            Issue.record("the failed write should reach the stream as an error, got \(String(describing: first))")
            return
        }
        #expect(failure.message.contains("Could not store"))
        #expect(JSONValue.parse(failure.raw)?["subtype"]?.stringValue == "storage")

        #expect(await runner.lastPersistenceFailure != nil)
        #expect(await runner.persistenceFailureCount == 1)
        #expect(try await store.messageCount(sessionID: session.id) == 0)
    }
}

// MARK: - Git.runRaw cancellation

@Suite("Git.runRaw cancellation", .scratchDirectory)
struct GitRunRawCancellationTests {
    /// `Shell.run` refuses a caller that has already given up, so spawning and terminating in the
    /// same breath cannot happen; `runRaw` sat beside it without the same gate, so the refresh
    /// loop's deadline cancelled a queue of raw git calls that all still forked.
    @Test("a cancelled caller is refused before git is spawned")
    func cancelledCallerThrows() async {
        let task = Task { () -> GitOutput in
            // Waits until the cancel below has landed, so the call is deterministic rather than a
            // race between this task starting and the test cancelling it.
            while !Task.isCancelled { await Task.yield() }
            return try await Git.runRaw(["status", "--porcelain", "-z"], in: "/tmp")
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}
