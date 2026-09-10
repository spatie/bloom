import Foundation
import Testing
import BloomClient
@testable import BloomCore

/// These vectors come from the production Codable types, not a second hand-written wire codec.
struct ServerProtocolVectorTests {
    @Test func encodeCrossLanguageVectors() throws {
        let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let workspace = WorkspaceID("workspace-example")
        let sessionID = SessionID("session-example")
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        let session = Session(id: sessionID, workspaceID: workspace, model: "example-model", effort: "medium", createdAt: epoch, updatedAt: epoch)
        let message = Message(id: 7, sessionID: sessionID, seq: 1, kind: .assistantText,
                              payload: Data("{\"text\":\"Hello\\nworld\"}".utf8), createdAt: epoch)
        let lease = RemoteUILease(id: id, token: "example-ui-lease", workspaceID: workspace, expiresAtMilliseconds: 1_800_000_030_000)
        let uiRequest = RemoteUIRequest(id: id, workspaceID: workspace, action: RemoteUIAction(name: "pane_open", arguments: .object(["kind": .string("browser"), "url": .string("http://localhost:3000")])), expiresAtMilliseconds: 1_800_000_020_000)
        let repo = Repo(id: RepoID("repo-example"), name: "Project", path: "/server/project", createdAt: epoch)
        let archived = Workspace(id: WorkspaceID("archived-example"), repoID: repo.id, name: "Archived work", branch: "archived", path: "/server/archived", baseBranch: "main", createdAt: epoch, lastActivityAt: epoch)
        let controls = ComposerControls(model: "example-model", effort: "medium", agentKind: .codex, permissionMode: .plan)
        let operations: [(String, ServerOperation)] = [
            ("uiAttach", .uiBridge(.attach(workspaceID: workspace, clientID: id, actions: ["pane_open"]))),
            ("uiClaim", .uiBridge(.claim(leaseID: id, token: lease.token, requestID: id))),
            ("uiRespond", .uiBridge(.respond(leaseID: id, token: lease.token, requestID: id, result: .init(text: "Opened Browser")))),
            ("hello", .hello), ("catalogue", .catalogue),
            ("diagnostics", .diagnostics),
            ("composer", .composer(sessionID: sessionID)),
            ("setComposer", .setComposer(sessionID: sessionID, controls: controls)),
            ("send", .send(sessionID: sessionID, text: "Run tests")),
            ("retryAuthentication", .send(sessionID: sessionID, text: "Run tests", retryDeliveryID: DeliveryID("delivery-example"))),
            ("stop", .stop(sessionID: sessionID)),
            ("cancelQueued", .cancelQueued(sessionID: sessionID, deliveryID: DeliveryID("delivery-example"))),
            ("markRead", .markRead(sessionID: sessionID, seq: 1)),
            ("renameSession", .renameSession(sessionID: sessionID, title: "Review")),
            ("closeSession", .closeSession(sessionID: sessionID)),
            ("terminalStream", .terminalStream(workspaceID: workspace, name: "Terminal")),
            ("archivePreview", .workspace(workspaceID: workspace, action: .archivePreview)),
            ("archive", .workspace(workspaceID: workspace, action: .archive(confirmation: id))),
            ("restore", .workspace(workspaceID: workspace, action: .restore)),
            ("transcript", .transcript(sessionID: sessionID, afterSeq: 0)),
            ("snapshot", .reviewSnapshot(workspaceID: workspace, scope: .branch, knownRevision: nil, wait: true)),
            ("patch", .reviewPatch(workspaceID: workspace, path: "README.md", scope: .uncommitted, knownRevision: "revision-1")),
            ("file", .file(workspaceID: workspace, path: "README.md")),
            ("files", .workspace(workspaceID: workspace, action: .files)),
            ("browserAddress", .workspace(workspaceID: workspace, action: .browserAddress)),
            ("upload", .workspace(workspaceID: workspace, action: .uploadFile(name: "note.txt", data: Data([0, 1, 255])))),
            ("clearColour", .workspace(workspaceID: workspace, action: .setColour(nil))),
            ("settings", .project(repoID: RepoID("repo-example"), action: .settings)),
            ("context", .creation(.workspaceContext(RepoID("repo-example")))),
            ("answer", .answer(sessionID: sessionID, requestID: "ask-example", answer: .question(input: .object(["choice": .string("yes")]))))
        ]
        let results: [(String, ServerResult)] = [
            ("uiAttached", .uiBridge(.attached(lease))),
            ("uiClaimed", .uiBridge(.claimed(true))),
            ("uiRequests", .uiBridge(.requests(.init(lease: lease, requests: [uiRequest])))),
            ("catalogue", .catalogue(.init(repositories: [repo], workspaces: [], sessions: [session], archivedWorkspaces: [archived]))),
            ("composer", .composer(.init(controls: controls, models: [], commands: [], styles: [], availableAgents: [.codex]))),
            ("composerAuthentication", .composer(.init(controls: controls, authentication: [.init(agent: .codex, state: .signInRequired)]))),
            ("archivePreview", .archivePreview(.init(id: id, workspace: archived,
                report: .init(hasUncommittedChanges: true, untrackedFiles: ["notes.txt"], unpushedCommits: 2, modifiedIgnoredFiles: [".env"]),
                hazards: .init(isAgentRunning: true, isDeletingBranch: true), createdAt: epoch))),
            ("terminal", .terminal(.init(executable: "/usr/local/bin/bloom-server", socket: "/tmp/bloom-terminal-example.sock", session: "terminal-example"))),
            ("hello", .hello(name: "example-server")), ("accepted", .accepted), ("failure", .failure("Example refusal")),
            ("snapshot", .reviewSnapshot(.init(revision: "revision-1", files: [.init(path: "README.md", change: .modified, additions: 2, deletions: 1)]))),
            ("unchangedSnapshot", .reviewSnapshot(.init(revision: "revision-1", files: nil))),
            ("unchangedPatch", .reviewPatch(.init(revision: "revision-1", patch: nil))),
            ("file", .file(.init(path: "README.md", text: "# Hello\n"))),
            ("browserAddress", .text("http://localhost:8000/admin")),
            ("download", .download(.init(path: "note.txt", data: Data([0, 1, 255])))),
            ("transcript", .transcript(.init(session: session, messages: [message], pendingQuestions: [Data("{}".utf8)], isBusy: false,
                                           streamingText: "", permissionDecisions: ["ask-example": "allowed"], queuedPrompts: [.init(id: DeliveryID("delivery-example"), text: "Next task")], queueError: nil)))
        ]
        var vectors: [[String: Any]] = []
        for (name, operation) in operations {
            let value = ServerRequest(operation, id: id)
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(ServerRequest.self, from: data)
            #expect(decoded == value)
            vectors.append(["name": "request-" + name, "value": try JSONSerialization.jsonObject(with: data)])
        }
        for (name, result) in results {
            let data = try JSONEncoder().encode(ServerReply(id: id, result: result))
            vectors.append(["name": "reply-" + name, "value": try JSONSerialization.jsonObject(with: data)])
        }
        let encodedMessage = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        #expect(encodedMessage["createdAt"] as? Double == 0)
        #expect(encodedMessage["sessionID"] as? String == "session-example")
        #expect(encodedMessage["payload"] as? String == message.payload.base64EncodedString())
        if let output = ProcessInfo.processInfo.environment["BLOOM_PROTOCOL_VECTORS"] {
            let data = try JSONSerialization.data(withJSONObject: vectors, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}
