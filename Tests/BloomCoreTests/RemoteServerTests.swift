import Foundation
import Testing
@testable import BloomCore

private let remoteTestEnvironment = ProcessInfo.processInfo.environment

/// Opt in only against a disposable server configured with Tests/fixtures/server-agent.py.
/// Exercises the same SSH client used by the Mac window, without opening the owner's app.
@Suite("RemoteServer", .enabled(if: remoteTestEnvironment["BLOOM_REMOTE_TEST_HOST"] != nil), .tags(.subprocess))
struct RemoteServerTests {
    @Test(.timeLimit(.minutes(2)))
    func reconnectApproveReviewStopAndContinue() async throws {
        let endpoint = ServerEndpoint.ssh(
            host: try #require(remoteTestEnvironment["BLOOM_REMOTE_TEST_HOST"]),
            executable: try #require(remoteTestEnvironment["BLOOM_REMOTE_TEST_EXECUTABLE"]),
            directory: try #require(remoteTestEnvironment["BLOOM_REMOTE_TEST_DIRECTORY"])
        )
        let first = try await ServerClient.connect(to: endpoint)
        let created = try await first.request(ServerRequest(.create(ServerWorkspaceRequest(
            repositoryPath: try #require(remoteTestEnvironment["BLOOM_REMOTE_TEST_REPOSITORY"]),
            name: "Remote validation " + String(UUID().uuidString.prefix(8)), model: "fixture"
        ))))
        guard case .created(let session, let workspace, _) = created.result else {
            Issue.record("Server did not create a workspace")
            await first.disconnect()
            return
        }
        let marker = try await first.request(ServerRequest(.file(workspaceID: workspace.id, path: "bloom-validation.txt")))
        guard case .file(let file) = marker.result, file.text == "Bloom remote protocol fixture\n" else {
            Issue.record("Refusing to send prompts outside the fixture repository")
            await first.disconnect()
            return
        }
        _ = try await first.request(ServerRequest(.send(sessionID: session.id, text: "approval")))
        await first.disconnect()

        let second = try await ServerClient.connect(to: endpoint)
        await waitUntil("approval survives the SSH disconnect", within: .seconds(20)) {
            let transcript = try? await readTranscript(second, sessionID: session.id)
            return transcript?.pendingQuestions.isEmpty == false && transcript?.isBusy == true
        }
        let pending = try await readTranscript(second, sessionID: session.id)
        let payload = try #require(pending.pendingQuestions.first)
        let ask = try #require(PermissionAsk.decode(payload: payload))
        _ = try await second.request(ServerRequest(.answer(sessionID: session.id, requestID: ask.requestID, answer: .allowOnce)))
        await waitUntil("approved turn completes", within: .seconds(20)) {
            let transcript = try? await readTranscript(second, sessionID: session.id)
            return transcript?.isBusy == false && transcript?.messages.contains { $0.kind == .result } == true
        }
        let contents = try await second.request(ServerRequest(.file(workspaceID: workspace.id, path: "hello.txt")))
        if case .file(let file) = contents.result { #expect(file.text == "Changed by the remote fixture\n") } else { Issue.record("Missing remote file") }
        let changes = try await second.request(ServerRequest(.changes(workspaceID: workspace.id, scope: .uncommitted)))
        if case .changes(let files) = changes.result { #expect(files.contains { $0.path == "hello.txt" }) } else { Issue.record("Missing remote changes") }
        let patch = try await second.request(ServerRequest(.patch(workspaceID: workspace.id, path: "hello.txt", scope: .uncommitted)))
        if case .patch(let text) = patch.result { #expect(text.contains("+Changed by the remote fixture")) } else { Issue.record("Missing remote patch") }

        _ = try await second.request(ServerRequest(.send(sessionID: session.id, text: "wait")))
        await second.disconnect()
        let third = try await ServerClient.connect(to: endpoint)
        #expect(try await readTranscript(third, sessionID: session.id).isBusy)
        _ = try await third.request(ServerRequest(.stop(sessionID: session.id)))
        await waitUntil("remote process stops", within: .seconds(20)) {
            (try? await readTranscript(third, sessionID: session.id).isBusy) == false
        }
        _ = try await third.request(ServerRequest(.send(sessionID: session.id, text: "finish")))
        await waitUntil("conversation resumes after stop", within: .seconds(20)) {
            let transcript = try? await readTranscript(third, sessionID: session.id)
            return transcript?.isBusy == false && transcript?.messages.filter { $0.kind == .result }.count == 2
        }
        await third.disconnect()
    }

    private func readTranscript(_ client: ServerClient, sessionID: SessionID) async throws -> ServerTranscript {
        let reply = try await client.request(ServerRequest(.transcript(sessionID: sessionID, afterSeq: -1)))
        guard case .transcript(let transcript) = reply.result else { throw ServerFailure("Missing remote transcript") }
        return transcript
    }
}
