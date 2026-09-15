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
            ("storage", .storage),
            ("skillsInspect", .skills(.init(action: .inspect, workspaceID: workspace))),
            ("skillsImport", .skills(.init(action: .previewImport, files: [.init(path: "example/SKILL.md", data: Data("# Example".utf8))]))),
            ("skillsApply", .skills(.init(action: .apply, planID: "example-plan", selectedSkillNames: ["example"], agents: [.claude, .codex]))),
            ("cleanupStorage", .cleanupStorage(targets: [.buildCache, .unusedImages])),
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
            ("archiveRemovingDocker", .workspace(workspaceID: workspace, action: .archive(confirmation: id, removingDocker: true))),
            ("removeStorageLeftovers", .removeStorageLeftovers(workspaceIDs: [WorkspaceID("archived-example")])),
            ("deletePreview", .workspace(workspaceID: workspace, action: .deletePreview)),
            ("delete", .workspace(workspaceID: workspace, action: .delete(confirmation: id))),
            ("removalPreview", .project(repoID: RepoID("repo-example"), action: .removalPreview)),
            ("removeProject", .project(repoID: RepoID("repo-example"), action: .remove(confirmation: id))),
            ("transcript", .transcript(sessionID: sessionID, afterSeq: 0)),
            ("snapshot", .reviewSnapshot(workspaceID: workspace, scope: .branch, knownRevision: nil, wait: true)),
            ("patch", .reviewPatch(workspaceID: workspace, path: "README.md", scope: .uncommitted, knownRevision: "revision-1")),
            ("file", .file(workspaceID: workspace, path: "README.md")),
            ("files", .workspace(workspaceID: workspace, action: .files)),
            ("browserAddress", .workspace(workspaceID: workspace, action: .browserAddress)),
            ("setupOutput", .workspace(workspaceID: workspace, action: .setupOutput)),
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
            ("composerCodexSpeeds", .composer(.init(controls: controls, availableAgents: [.codex],
                codexSpeeds: ["example-model": .init(isFast: true, supportsFast: true)]))),
            ("archivePreview", .archivePreview(.init(id: id, workspace: archived,
                report: .init(hasUncommittedChanges: true, untrackedFiles: ["notes.txt"], unpushedCommits: 2, modifiedIgnoredFiles: [".env"]),
                hazards: .init(isAgentRunning: true, isDeletingBranch: true), createdAt: epoch))),
            ("archivePreviewDocker", .archivePreview(.init(id: id, workspace: archived, report: .init(),
                hazards: .init(isAgentRunning: false, isDeletingBranch: false), createdAt: epoch,
                docker: .init(resources: [.init(kind: .container, name: "example-app-1", composeProject: "example", isRunning: true),
                                          .init(kind: .volume, name: "example_data", composeProject: "example", sizeLabel: "120MB")])))),
            ("storageLeftovers", .storage(.init(checkedAt: epoch, dockerState: .ready, leftovers: [
                .init(workspaceID: WorkspaceID("archived-example"), workspaceName: "Archived work", owner: .archived,
                      resources: [.init(kind: .volume, name: "example_data", sizeLabel: "120MB")]),
                .init(workspaceID: WorkspaceID("missing-example"), owner: .unknown, resources: [.init(kind: .network, name: "example_default")]),
            ]))),
            ("storageLeftoverRemoval", .storageLeftoverRemoval(.init(outcomes: [
                .init(workspaceID: WorkspaceID("archived-example"), status: .completed, message: "Removed 1 volume"),
            ]))),
            ("removalPreview", .removalPreview(.init(id: id, title: "Remove Project?",
                message: "Bloom Server forgets this project and permanently deletes everything it kept about its workspaces.",
                confirmLabel: "Remove Project", cancelLabel: "Keep Project", createdAt: epoch))),
            ("removalBlocked", .removalPreview(.init(id: id, title: "Project cannot be removed yet", message: "Archive it first.",
                confirmLabel: "Remove Project", cancelLabel: "OK", blocker: "Archive it first.", createdAt: epoch))),
            ("terminal", .terminal(.init(executable: "/usr/local/bin/bloom-server", socket: "/tmp/bloom-terminal-example.sock", session: "terminal-example"))),
            ("storage", .storage(.init(checkedAt: epoch, totalBytes: 42_949_672_960, freeBytes: 8_589_934_592,
                dockerState: .ready, usage: [.init(kind: "Build Cache", totalCount: 12, activeCount: 2, sizeLabel: "1.2GB", reclaimableLabel: "200MB (16%)")]))),
            ("storageCleanup", .storageCleanup(.init(outcomes: [
                .init(target: .buildCache, status: .completed, message: "Unused cache removed", reclaimedLabel: "200MB"),
                .init(target: .unusedImages, status: .uncertain, message: "Refresh storage before retrying"),
            ], interrupted: true))),
            ("skillsCapability", .diagnostics(.init(checkedAt: epoch, hostname: "example-server", operatingSystem: "Ubuntu", account: "bloom", checks: [], skillManagement: true))),
            ("skillsPlan", .skills(.init(plan: .init(id: "example-plan", source: .personal,
                skills: [.init(id: "example-skill", name: "example", description: "Example skill", source: .personal,
                    revision: "example-revision", enabledAgents: [], fileCount: 1, byteCount: 9, path: "example/SKILL.md", filePaths: ["SKILL.md"])],
                repositoryURL: nil, commit: nil, collectionID: "example-collection", expiresAt: epoch, warnings: [])))),
            ("storageCapability", .diagnostics(.init(checkedAt: epoch, hostname: "example-server", operatingSystem: "Ubuntu", account: "bloom", checks: [], storageManagement: true))),
            ("hello", .hello(name: "example-server")), ("accepted", .accepted), ("failure", .failure("Example refusal")),
            ("snapshot", .reviewSnapshot(.init(revision: "revision-1", files: [.init(path: "README.md", change: .modified, additions: 2, deletions: 1)]))),
            ("unchangedSnapshot", .reviewSnapshot(.init(revision: "revision-1", files: nil))),
            ("unchangedPatch", .reviewPatch(.init(revision: "revision-1", patch: nil))),
            ("file", .file(.init(path: "README.md", text: "# Hello\n"))),
            ("browserAddress", .text("http://localhost:8000/admin")),
            ("setupOutput", .setupOutput(.init(state: .running, log: "Installing dependencies from lock file\n", startedAt: epoch))),
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
