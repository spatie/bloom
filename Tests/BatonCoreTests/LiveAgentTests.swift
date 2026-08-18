import Testing
import Foundation
@testable import BatonCore

/// End to end against the real `claude` binary.
///
/// Every other test in the suite is hermetic. These are not: they spend tokens, need auth, and
/// need the network, so they only run when asked for:
///
///     BATON_LIVE=1 ./test-core.sh LiveAgent
///
/// They exist because the agent protocol is the one part of Baton that cannot be proven correct
/// against a fixture. A fixture only proves we still decode what the CLI emitted the day it was
/// captured.
private let liveEnabled = ProcessInfo.processInfo.environment["BATON_LIVE"] == "1"

@Suite("LiveAgent", .enabled(if: liveEnabled), .tags(.subprocess), .scratchDirectory)
struct LiveAgentTests {
    private func makeWorkspace() async throws -> (store: Store, session: Session, path: String, repo: TempRepo) {
        let repo = try await TempRepo()
        try repo.write("notes.txt", "the secret word is pelican\n")
        try await repo.commit("notes")

        let store = try makeTestStore("live")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        let workspace = try await manager.createWorkspace(repo: registered, prompt: "Live protocol check")
        let session = try await store.upsert(Session(
            workspaceID: workspace.id,
            model: "haiku",
            permissionMode: .bypassPermissions
        ))
        return (store, session, workspace.path, repo)
    }

    @Test("drives a real agent turn from prompt to result", .timeLimit(.minutes(5)))
    func drivesARealTurn() async throws {
        let (store, session, path, repo) = try await makeWorkspace()
        defer { repo.cleanUp() }

        let runner = AgentRunner(workspacePath: path, session: session, store: store)

        let collected = EventLog()
        let pump = Task {
            for await event in runner.events { collected.record(event) }
        }

        try await runner.send("Read notes.txt and reply with only the secret word, nothing else.")

        // Wait for the result event rather than a fixed sleep.
        let deadline = Date().addingTimeInterval(180)
        while !collected.sawResult, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        pump.cancel()

        #expect(collected.sawResult, "the agent never emitted a result event")
        #expect(collected.sawInit, "the agent never emitted an init event")
        #expect(collected.sawToolUse, "the agent never called a tool, so Read was not exercised")
        // Unmodelled `stream_event` sub-variants (message_start, message_delta, signature_delta
        // and so on) legitimately fall through to .unknown, because StreamDelta only models what
        // the UI draws. A top-level event type falling through would be a real gap, so that is
        // what this asserts.
        #expect(
            collected.unknownTopLevelTypes.isEmpty,
            "decoder did not recognise these top level types: \(collected.unknownTopLevelTypes)"
        )

        // The session id must have been persisted, or resume can never work.
        let stored = try await store.session(id: session.id)
        #expect(stored?.agentSessionID != nil)
        #expect(stored?.state == .idle)

        // Every event must have reached the store as a row, in order.
        let rows = try await store.messages(sessionID: session.id)
        #expect(rows.count > 3)
        #expect(rows.map(\.seq) == Array(0..<rows.count))

        // A tool use row must be findable by its reference id, which is what pairs it with its
        // result in the transcript.
        let toolRows = rows.filter { $0.kind == .toolUse }
        #expect(toolRows.isEmpty == false)
        for row in toolRows {
            let refID = try #require(row.refID)
            #expect(try await store.message(sessionID: session.id, refID: refID) != nil)
        }

        #expect(collected.resultSummary.lowercased().contains("pelican"))
    }

    @Test("resumes a session so context survives a relaunch", .timeLimit(.minutes(5)))
    func resumesASession() async throws {
        let (store, session, path, repo) = try await makeWorkspace()
        defer { repo.cleanUp() }

        let first = AgentRunner(workspacePath: path, session: session, store: store)
        let firstLog = EventLog()
        let firstPump = Task { for await event in first.events { firstLog.record(event) } }
        try await first.send("Remember the number 4271. Reply with just OK.")

        let deadline = Date().addingTimeInterval(120)
        while !firstLog.sawResult, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        firstPump.cancel()
        #expect(firstLog.sawResult)

        let resumed = try #require(try await store.session(id: session.id))
        #expect(resumed.agentSessionID != nil)

        // A brand new runner, given the persisted agent session id, must see the earlier turn.
        let second = AgentRunner(workspacePath: path, session: resumed, store: store)
        let secondLog = EventLog()
        let secondPump = Task { for await event in second.events { secondLog.record(event) } }
        try await second.send("What number did I ask you to remember? Reply with just the number.")

        let secondDeadline = Date().addingTimeInterval(120)
        while !secondLog.sawResult, Date() < secondDeadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        secondPump.cancel()

        #expect(secondLog.sawResult)
        #expect(secondLog.resultSummary.contains("4271"), "resume did not carry the earlier turn")
    }

    @Test("cancelling a turn stops the process", .timeLimit(.minutes(3)))
    func cancelsATurn() async throws {
        let (store, session, path, repo) = try await makeWorkspace()
        defer { repo.cleanUp() }

        let runner = AgentRunner(workspacePath: path, session: session, store: store)
        let log = EventLog()
        let pump = Task { for await event in runner.events { log.record(event) } }

        try await runner.send("Count slowly from 1 to 500, one number per line.")
        // Let it get going, then pull the plug.
        try await Task.sleep(for: .seconds(4))
        #expect(await runner.isRunning)

        runner.cancelNow()

        let deadline = Date().addingTimeInterval(20)
        while await runner.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        pump.cancel()

        #expect(await runner.isRunning == false, "the process was still alive 20 seconds after cancelling")

        // Cancellation bookkeeping is persisted from a detached task, so the state settles a
        // moment after the process dies. Poll rather than reading once.
        var stored = try await store.session(id: session.id)
        let settleBy = Date().addingTimeInterval(5)
        while stored?.state == .running, Date() < settleBy {
            try await Task.sleep(for: .milliseconds(100))
            stored = try await store.session(id: session.id)
        }
        #expect(stored?.state == .cancelled, "left the session in \(stored?.state.rawValue ?? "nil")")
    }
}

/// Thread-safe tally of what came out of a live run.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sawInit = false
    private(set) var sawResult = false
    private(set) var sawToolUse = false
    private(set) var unknownCount = 0
    private(set) var unknownSamples: [String] = []
    private(set) var resultSummary = ""
    private var unknownTypes: Set<String> = []

    /// Top-level `type` values that fell through to `.unknown`, excluding `stream_event`, whose
    /// sub-variants are deliberately not all modelled.
    var unknownTopLevelTypes: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return unknownTypes.subtracting(["stream_event"])
    }

    func record(_ event: AgentEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .initialized: sawInit = true
        case .toolUse: sawToolUse = true
        case .result(let result):
            sawResult = true
            resultSummary = result.summary
        case .unknown(let raw):
            unknownCount += 1
            let text = String(decoding: raw, as: UTF8.self)
            if let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
               let type = object["type"] as? String {
                unknownTypes.insert(type)
            }
            if unknownSamples.count < 3 {
                unknownSamples.append(String(text.prefix(200)))
            }
        default: break
        }
    }
}
