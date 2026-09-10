import Foundation
import Synchronization
import Testing
@testable import BloomCore

@Suite("ServerRuntime", .tags(.persistence, .subprocess), .scratchDirectory)
struct ServerRuntimeTests {
    @Test func setupPublishesOutputWhileQuietAndReplaysTheSameCommandWithoutRerunning() async throws {
        let fixture = try await ServerFixture()
        let workspaceID = try #require(fixture.session.workspaceID)
        let settings = fixture.directory + "/.bloom"
        try FileManager.default.createDirectory(atPath: settings, withIntermediateDirectories: true)
        try """
        [scripts]
        setup = "echo attempt >> attempts.txt; echo current-output; sleep 2; echo complete"
        """.write(toFile: settings + "/settings.toml", atomically: true, encoding: .utf8)
        let old = try await fixture.store.beginSetupAttempt(workspaceID: workspaceID)
        try await fixture.store.finishSetupAttempt(workspaceID: workspaceID, attempt: old, succeeded: false, log: "previous failure")
        let runtime = fixture.runtime()
        let request = ServerRequest(.workspace(workspaceID: workspaceID, action: .runSetup))
        let running = Task { await runtime.respond(to: request) }
        await waitUntil("live setup output reaches catalogue while the script is quiet") {
            guard let row = try? await fixture.store.workspace(id: workspaceID) else { return false }
            return row.setupState == .running && row.setupLog.contains("current-output")
        }
        let live = try #require(try await fixture.store.workspace(id: workspaceID))
        #expect(!live.setupLog.contains("previous failure"))
        #expect(!live.setupLog.contains("complete"))
        // The normal client polls scripts alongside the catalogue. Refusing that read used to
        // disconnect it as soon as setup acquired the workspace lifecycle lock.
        let scripts = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspaceID, action: .runScripts)))
        if case .runScripts = scripts.result {} else { Issue.record("Setup blocked client polling") }
        let replay = Task { await runtime.respond(to: request) }
        let duplicate = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspaceID, action: .runSetup)))
        #expect(!duplicate.isAccepted)
        #expect(await running.value.isAccepted)
        #expect(await replay.value.isAccepted)
        let repeated = await runtime.respond(to: request)
        #expect(repeated.isAccepted)
        #expect(try String(contentsOfFile: fixture.directory + "/attempts.txt", encoding: .utf8) == "attempt\n")
        #expect(try await fixture.store.workspace(id: workspaceID)?.setupLog == "current-output\ncomplete\n")
        await runtime.shutdown()
    }

    @Test(arguments: [SessionState.running, .waiting])
    func setupRefusesActiveAgentsAtTheServerBoundary(state: SessionState) async throws {
        let fixture = try await ServerFixture()
        let workspaceID = try #require(fixture.session.workspaceID)
        _ = try await fixture.store.update(sessionID: fixture.session.id) { $0.state = state }
        let runtime = fixture.runtime()
        let response = await runtime.respond(to: ServerRequest(.workspace(workspaceID: workspaceID, action: .runSetup)))
        #expect(response.failure?.contains("Stop the workspace's agents") == true)
        #expect(try await fixture.store.workspace(id: workspaceID)?.setupState != .running)
        await runtime.shutdown()
    }

    @Test func missingAgentIsRefusedBeforeCreatingAWorkspaceOrQueuingAPrompt() async throws {
        let fixture = try await ServerFixture()
        let runtime = fixture.runtime(availableAgents: [.codex])
        var request = ServerWorkspaceRequest(repositoryPath: fixture.directory, name: "Uninstalled agent")
        request.mode = .chat
        request.prompt = "What is in this repo?"
        let creation = await runtime.respond(to: ServerRequest(.create(request)))
        guard case .failure(let reason) = creation.result else { Issue.record("Missing agent was accepted"); return }
        #expect(reason.contains("Claude Code is not installed on this server"))
        #expect(try await fixture.store.workspaces().count == 1)
        let sent = await runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "Do not queue")))
        #expect(!sent.isAccepted)
        #expect(await fixture.runner.sends.isEmpty)
        await runtime.shutdown()
    }

    @Test func remoteDefaultsUseAnInstalledAgentAndKeepExplicitAvailableChoices() {
        let preferred = ComposerControls(model: "opus", effort: "max", agentKind: .claudeCode, permissionMode: .plan)
        let models = [CodexModel(id: "test-codex-model", displayName: "Test", isDefault: true, defaultEffort: "low")]
        let resolved = ServerAgentAvailability.defaults(preferred, available: [.codex], models: models)
        #expect(resolved.agentKind == .codex)
        #expect(resolved.model == "test-codex-model")
        #expect(resolved.effort == "low")
        #expect(resolved.permissionMode == preferred.permissionMode.nearest(on: .codex))
        #expect(ServerAgentAvailability.defaults(preferred, available: [.claudeCode, .codex], models: models) == preferred)
        #expect(ServerAgentAvailability.defaults(preferred, available: [], models: []) == preferred)
    }

    @Test func remoteAgentDiscoveryHonoursServerExecutableOverrides() async throws {
        let fixture = try await ServerFixture()
        try await fixture.store.setSetting(AgentCatalog.executablePathSettingKey(.claudeCode), fixture.directory + "/missing-claude")
        try await fixture.store.setSetting(AgentCatalog.executablePathSettingKey(.codex), "/bin/sh")
        let installed = await ServerAgentAvailability.installed(store: fixture.store)
        #expect(installed == [.codex])
    }

    @Test func agentAvailabilityIsAnOptionalWireField() throws {
        let state = ServerComposerState(controls: ComposerControls(), models: [], commands: [], styles: [])
        let legacy = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(ServerComposerState.self, from: legacy).availableAgents == nil)
        var current = state
        current.availableAgents = [.codex]
        let encoded = try JSONEncoder().encode(current)
        #expect(try JSONDecoder().decode(ServerComposerState.self, from: encoded).availableAgents == [.codex])
    }

    @Test func sharedCreationPreservesControlsAndUploadsTheOpeningPrompt() async throws {
        let repository = try await TempRepo()
        defer { repository.cleanUp() }
        let fixture = try await ServerFixture()
        let captured = Mutex<ServerTestRunner?>(nil)
        let runtime = ServerRuntime(store: fixture.store, authentication: { agent, _, _ in .init(agent: agent, state: .unknown) }, installedAgents: { _ in [.claudeCode, .codex] }, makeRunner: { session, _, store in
            let runner = ServerTestRunner(sessionID: session.id, store: store)
            captured.withLock { $0 = runner }
            return runner
        })
        var request = ServerWorkspaceRequest(repositoryPath: repository.path, name: "Attachment test")
        request.mode = .chat
        request.prompt = "Read .bloom/attachments/draft/notes.txt"
        request.controls = ComposerControls(model: "test-model", effort: "high", agentKind: .claudeCode, permissionMode: .plan)
        request.baseBranch = "main"
        request.runSetupScript = false
        request.attachments = [ServerInitialAttachment(sourcePath: ".bloom/attachments/draft/notes.txt", name: "notes.txt", data: Data("Attached content".utf8))]
        let wire = ServerRequest(.create(request))
        let encoded = try JSONEncoder().encode(wire)
        #expect(try JSONDecoder().decode(ServerRequest.self, from: encoded) == wire)
        let response = await runtime.respond(to: wire)
        guard case .creation(.workspaceStarted(let workspace, let session, _, _)) = response.result else {
            Issue.record("Creation failed: \(String(describing: response.result))"); await runtime.shutdown(); return
        }
        defer { try? FileManager.default.removeItem(atPath: workspace.path) }
        let id = try #require(session?.id)
        let stored = try #require(try await fixture.store.session(id: id))
        #expect(stored.model == "test-model")
        #expect(stored.effort == "high")
        #expect(workspace.baseBranch == "main")
        await waitUntil("opening prompt reaches runner") {
            guard let runner = captured.withLock({ $0 }) else { return false }
            return await runner.sends.count == 1
        }
        let runner = try #require(captured.withLock { $0 })
        let sent = try #require(await runner.sends.first)
        #expect(!sent.contains("/draft/"))
        let path = String(sent.dropFirst("Read ".count))
        #expect(try String(contentsOfFile: workspace.path + "/" + path, encoding: .utf8) == "Attached content")
        let replay = await runtime.respond(to: wire)
        if case .creation(.workspaceStarted(let repeated, _, _, _)) = replay.result { #expect(repeated.id == workspace.id) } else { Issue.record("Missing replay") }
        #expect(try await fixture.store.workspaces().count == 2)
        await runtime.shutdown()
    }

    @Test(arguments: [WorkspaceStartMode.terminal, .browser])
    func sharedCreationWithoutAnAgent(mode: WorkspaceStartMode) async throws {
        let repository = try await TempRepo()
        defer { repository.cleanUp() }
        let fixture = try await ServerFixture()
        let runtime = fixture.runtime(availableAgents: [])
        var request = ServerWorkspaceRequest(repositoryPath: repository.path, name: "Explore")
        request.mode = mode
        request.runSetupScript = false
        let response = await runtime.respond(to: ServerRequest(.create(request)))
        guard case .creation(.workspaceStarted(let workspace, let session, _, _)) = response.result else {
            Issue.record("Missing workspace: \(String(describing: response.result))"); await runtime.shutdown(); return
        }
        defer { try? FileManager.default.removeItem(atPath: workspace.path) }
        #expect(session == nil)
        #expect(try await fixture.store.sessions(workspaceID: workspace.id).isEmpty)
        #expect(await fixture.runner.sends.isEmpty)
        await runtime.shutdown()
    }

    @Test func sharedProjectInspectionAndRegistrationRejectChangedFolders() async throws {
        let repository = try await TempRepo()
        defer { repository.cleanUp() }
        let fixture = try await ServerFixture()
        let runtime = fixture.runtime()
        let inspected = await runtime.respond(to: ServerRequest(.creation(.inspectProject(repository.path))))
        guard case .creation(.inspection(let inspection)) = inspected.result else { Issue.record("Missing inspection"); return }
        var changed = inspection.facts
        changed.path += "/different"
        let refused = await runtime.respond(to: ServerRequest(.creation(.startProject(typed: repository.path, expected: changed))))
        #expect(!refused.isAccepted)
        let added = await runtime.respond(to: ServerRequest(.creation(.startProject(typed: repository.path, expected: inspection.facts))))
        guard case .creation(.project(let repo)) = added.result else { Issue.record("Missing project"); return }
        let root = try await Git.topLevel(of: repository.path)
        #expect(repo.path == root)
        let branches = await runtime.respond(to: ServerRequest(.creation(.checkouts(repo.id))))
        if case .creation(.checkouts) = branches.result {} else { Issue.record("Missing checkouts") }
        await runtime.shutdown()
    }

    @Test func failedRemoteSetupRetainsThePromptWithoutStartingAnAgent() async throws {
        let repository = try await TempRepo()
        defer { repository.cleanUp() }
        try repository.write(".conductor/settings.toml", "[scripts]\nsetup = \"exit 3\"\n")
        let fixture = try await ServerFixture()
        let runtime = fixture.runtime()
        var request = ServerWorkspaceRequest(repositoryPath: repository.path, name: "Setup failure")
        request.mode = .chat
        request.prompt = "Keep this task"
        request.runSetupScript = true
        let reply = await runtime.respond(to: ServerRequest(.create(request)))
        guard case .creation(.workspaceStarted(let workspace, let session, let succeeded, let draft)) = reply.result else {
            Issue.record("Missing failed setup result"); await runtime.shutdown(); return
        }
        defer { try? FileManager.default.removeItem(atPath: workspace.path) }
        #expect(succeeded == false)
        #expect(session != nil)
        #expect(draft == "Keep this task")
        #expect(await fixture.runner.sends.isEmpty)
        await runtime.shutdown()
    }

    @Test func githubRepositoryNamesCannotEscapeTheCloneDirectory() throws {
        #expect(try GitHubRepositoryBrowser.validatedName("spatie/bloom") == "spatie/bloom")
        for input in ["../bloom", "spatie/..", "/tmp/owned", "--config/x", "spatie/-x", "a/b/c", "a/b\n", "a/$(whoami)"] {
            #expect(throws: (any Error).self) { try GitHubRepositoryBrowser.validatedName(input) }
        }
        let json = Data(#"{"full_name":"spatie/bloom","description":null,"private":true}"#.utf8)
        let repo = try JSONDecoder().decode(GitHubRepositoryListing.self, from: json)
        #expect(repo.nameWithOwner == "spatie/bloom")
        #expect(repo.isPrivate)
    }

    @Test func closingAConversationStopsItsRunnerAndRefusesFurtherPrompts() async throws {
        let fixture = try await ServerFixture()
        let runtime = fixture.runtime()
        let sent = await runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "Work")))
        #expect(sent.isAccepted)
        await waitUntil("runner starts") { await fixture.runner.sends.count == 1 }
        let renamed = await runtime.respond(to: ServerRequest(.renameSession(sessionID: fixture.session.id, title: "Renamed")))
        #expect(renamed.isAccepted)
        #expect(try await fixture.store.session(id: fixture.session.id)?.title == "Renamed")
        let closed = await runtime.respond(to: ServerRequest(.closeSession(sessionID: fixture.session.id)))
        #expect(closed.isAccepted)
        #expect(try await fixture.store.session(id: fixture.session.id)?.archivedAt != nil)
        #expect(fixture.runner.terminated.withLock { $0 })
        let refused = await runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "Must not start")))
        #expect(!refused.isAccepted)
        #expect(await fixture.runner.sends == ["Work"])
        let catalogue = await runtime.respond(to: ServerRequest(.catalogue))
        if case .catalogue(let value) = catalogue.result {
            #expect(value.workspaces.count == 1)
            #expect(!value.sessions.contains { $0.id == fixture.session.id })
        } else { Issue.record("Missing catalogue") }
        await runtime.shutdown()
    }

    @Test func actualSSHHandshakeWhenExplicitlyConfigured() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["BLOOM_REMOTE_TEST_HOST"], let executable = env["BLOOM_REMOTE_TEST_EXECUTABLE"],
              let directory = env["BLOOM_REMOTE_TEST_DIRECTORY"] else { return }
        let client = try await ServerClient.connect(to: .ssh(host: host, executable: executable, directory: directory, identityFile: env["BLOOM_REMOTE_TEST_IDENTITY_FILE"]))
        for _ in 0..<3 {
            let reply = try await client.request(ServerRequest(.catalogue), timeout: .seconds(15))
            if case .catalogue = reply.result {} else { Issue.record("Missing catalogue") }
        }
        await client.disconnect()
    }

    @Test func concurrentReconnectsCannotReuseDescriptorsStillBeingWatched() async throws {
        let fixture = try await ServerFixture()
        let runner = fixture.runner
        let daemon = try await ServerDaemon.start(authentication: { agent, _, _ in .init(agent: agent, state: .unknown) }, directory: fixture.directory, installedAgents: { _ in [.claudeCode, .codex] }, makeRunner: { _, _, _ in runner })
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        for _ in 0..<25 {
                            let client = try await ServerClient.connect(to: .local(directory: fixture.directory))
                            let reply = try await client.request(ServerRequest(.catalogue))
                            if case .catalogue = reply.result {} else { Issue.record("Lost connection during descriptor reuse") }
                            await client.disconnect()
                        }
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            await daemon.shutdown()
            throw error
        }
        await daemon.shutdown()
    }

    @Test func realAgentProcessSurvivesDisconnectAndAcceptsAnotherTurn() async throws {
        let fixture = try await ServerFixture()
        let script = fixture.directory + "/agent-fixture.sh"
        try Self.agentScript.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        try await fixture.store.setSetting(AgentCatalog.executablePathSettingKey(.claudeCode), script)
        let child = Mutex<StreamingProcess?>(nil)
        let daemon = try await ServerDaemon.start(authentication: { agent, _, _ in .init(agent: agent, state: .unknown) }, directory: fixture.directory, installedAgents: { _ in [.claudeCode, .codex] }, makeRunner: { session, path, store in
            AgentRunner(workspacePath: path, session: session, store: store, makeProcess: { launch in
                #expect(launch.executable == script)
                // Always run the fixture, even if executable selection regresses. This test must
                // never fall through to an installed agent or make a paid model request.
                let process = StreamingProcess(executable: "/bin/sh", arguments: [script], cwd: path, mergeStderr: false)
                child.withLock { $0 = process }
                return process
            })
        })
        do {
            let first = try await ServerClient.connect(to: .local(directory: fixture.directory))
            _ = try await first.request(ServerRequest(.send(sessionID: fixture.session.id, text: "First")))
            await waitUntil("child receives the first prompt") {
                FileManager.default.fileExists(atPath: fixture.directory + "/ready")
            }
            await first.disconnect()
            #expect(child.withLock { $0?.isRunning } == true)

            let second = try await ServerClient.connect(to: .local(directory: fixture.directory))
            let busy = try await second.request(ServerRequest(.transcript(sessionID: fixture.session.id, afterSeq: -1)))
            if case .transcript(let transcript) = busy.result { #expect(transcript.isBusy) } else { Issue.record("Missing transcript") }
            try Data().write(to: URL(fileURLWithPath: fixture.directory + "/release"))
            await waitUntil("disconnected work finishes") {
                (try? await fixture.store.session(id: fixture.session.id)?.state) == .idle
            }
            let continued = try await second.request(ServerRequest(.send(sessionID: fixture.session.id, text: "Second")))
            #expect(continued.isAccepted)
            await waitUntil("second turn is persisted") {
                let reply = await daemon.runtime.respond(to: ServerRequest(.transcript(sessionID: fixture.session.id, afterSeq: -1)))
                if case .transcript(let transcript) = reply.result {
                    return !transcript.isBusy && transcript.messages.filter { $0.kind == .result }.count == 2
                }
                return false
            }
            let prompts = try String(contentsOfFile: fixture.directory + "/prompts", encoding: .utf8)
            #expect(prompts.split(separator: "\n").count == 2)
            #expect(prompts.contains("First") && prompts.contains("Second"))
            await second.disconnect()
        } catch {
            await daemon.shutdown()
            throw error
        }
        await daemon.shutdown()
        #expect(child.withLock { $0?.isRunning } == false)
    }

    private static let agentScript = #"""
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"fixture","model":"sonnet"}'
    while IFS= read -r prompt; do
        printf '%s\n' "$prompt" >> prompts
        touch ready
        attempts=0
        while [ ! -f release ]; do
            attempts=$((attempts + 1))
            [ "$attempts" -lt 1000 ] || exit 1
            sleep 0.01
        done
        printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"duration_api_ms":1,"duration_ms":1,"result":"Completed","session_id":"fixture"}'
    done
    """#

    @Test func concurrentRetriesLaunchOneTurn() async throws {
        let fixture = try await ServerFixture()
        let runtime = fixture.runtime()
        let request = ServerRequest(.send(sessionID: fixture.session.id, text: "First turn"))
        async let first = runtime.respond(to: request)
        async let second = runtime.respond(to: request)
        let replies = await [first, second]
        for reply in replies { #expect(reply.isAccepted) }
        await waitUntil("queued retry is delivered once") { await fixture.runner.sends == ["First turn"] }

        let changed = await runtime.respond(to: ServerRequest(.stop(sessionID: fixture.session.id), id: request.id))
        #expect(changed.failure?.contains("reused") == true)
        #expect(fixture.runner.stops.withLock { $0 } == 0)
        await runtime.shutdown()
    }

    @Test func distinctPromptsCannotRaceIntoOneRunner() async throws {
        let fixture = try await ServerFixture()
        let runtime = fixture.runtime()
        async let first = runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "One")))
        async let second = runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "Two")))
        let replies = await [first, second]
        #expect(replies.allSatisfy { $0.isAccepted })
        await waitUntil("first queued turn starts") { await fixture.runner.sends.count == 1 }
        #expect(try await fixture.store.pendingDeliveries(sessionID: fixture.session.id).count >= 1)
        await fixture.runner.finish()
        await waitUntil("second turn runs after the first finishes") { await fixture.runner.sends.count == 2 }
        await runtime.shutdown()
    }

    @Test func disconnectLeavesAgentAliveAndAnotherClientCanContinue() async throws {
        let fixture = try await ServerFixture()
        let runner = fixture.runner
        let daemon = try await ServerDaemon.start(authentication: { agent, _, _ in .init(agent: agent, state: .unknown) }, directory: fixture.directory, installedAgents: { _ in [.claudeCode, .codex] }, makeRunner: { _, _, _ in runner })
        let first = try await ServerClient.connect(to: .local(directory: fixture.directory))
        _ = try await first.request(ServerRequest(.send(sessionID: fixture.session.id, text: "Keep working")))
        await first.disconnect()
        #expect(runner.terminated.withLock { $0 } == false)

        let second = try await ServerClient.connect(to: .local(directory: fixture.directory))
        await waitUntil("queued prompt reaches the transcript") { (try? await fixture.store.messages(sessionID: fixture.session.id).count) == 1 }
        let reply = try await second.request(ServerRequest(.transcript(sessionID: fixture.session.id, afterSeq: -1)))
        guard case .transcript(let transcript) = reply.result else { Issue.record("Missing transcript"); return }
        #expect(transcript.isBusy)
        #expect(transcript.messages.count == 1)
        await runner.finish()
        await waitUntil("finished turn reaches runtime") {
            let reply = await daemon.runtime.respond(to: ServerRequest(.transcript(sessionID: fixture.session.id, afterSeq: -1)))
            if case .transcript(let transcript) = reply.result { return !transcript.isBusy }
            return false
        }
        _ = try await second.request(ServerRequest(.send(sessionID: fixture.session.id, text: "Continue")))
        await waitUntil("continued prompt is delivered") { await runner.sends == ["Keep working", "Continue"] }
        await second.disconnect()
        await daemon.shutdown()
        #expect(runner.terminated.withLock { $0 })
    }

    @Test func completedCommandIsNotReplayedAfterServerRestart() async throws {
        let fixture = try await ServerFixture()
        let first = fixture.runtime()
        let request = ServerRequest(.send(sessionID: fixture.session.id, text: "Do this once"))
        let reply = await first.respond(to: request)
        #expect(reply.isAccepted)
        await waitUntil("original turn starts") { await fixture.runner.sends.count == 1 }
        await first.shutdown()
        let second = fixture.runtime()
        let replay = await second.respond(to: request)
        #expect(replay.isAccepted)
        await waitUntil("accepted prompt is delivered") { await fixture.runner.sends.count == 1 }
        await second.shutdown()
    }

    @Test func interruptedCommandRequiresInspectionInsteadOfReplay() async throws {
        let fixture = try await ServerFixture()
        let request = ServerRequest(.send(sessionID: fixture.session.id, text: "Uncertain outcome"))
        let record = try JSONEncoder().encode(ServerCommandRecord(request: request))
        try await fixture.store.setSetting("server.command.\(request.id.uuidString)", String(decoding: record, as: UTF8.self))
        let runtime = fixture.runtime()
        let reply = await runtime.respond(to: request)
        #expect(reply.failure?.contains("Inspect") == true)
        #expect(await fixture.runner.sends.isEmpty)
        await runtime.shutdown()
    }

    @Test func staleAndConcurrentApprovalsAreRefused() async throws {
        let fixture = try await ServerFixture()
        let runtime = fixture.runtime()
        _ = await runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "Wait")))
        await waitUntil("the queued turn starts before its permission question") { await fixture.runner.sends.count == 1 }
        let raw = Data(#"{"type":"control_request","request_id":"question-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"pwd"}}}"#.utf8)
        let ask = try #require(PermissionAsk.decode(payload: raw))
        try await fixture.store.appendPermissionAsk(sessionID: fixture.session.id, ask: ask)
        let operation = ServerOperation.answer(sessionID: fixture.session.id, requestID: ask.requestID, answer: .allowOnce)
        async let first = runtime.respond(to: ServerRequest(operation))
        async let second = runtime.respond(to: ServerRequest(operation))
        let replies = await [first, second]
        #expect(replies.filter(\.isAccepted).count == 1)
        #expect(await fixture.runner.answers == 1)
        let stale = await runtime.respond(to: ServerRequest(operation))
        #expect(stale.failure != nil)
        await runtime.shutdown()
    }

    @Test func protocolMismatchCannotExecuteACommand() async throws {
        let fixture = try await ServerFixture()
        let runtime = fixture.runtime()
        let reply = await runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "No"), version: 999))
        #expect(reply.failure?.contains("protocol") == true)
        #expect(await fixture.runner.sends.isEmpty)
        await runtime.shutdown()
    }

    @Test func secondServerCannotResetLiveStateOrReplaceSocket() async throws {
        let fixture = try await ServerFixture()
        let directory = fixture.directory
        let runner = fixture.runner
        let first = try await ServerDaemon.start(authentication: { agent, _, _ in .init(agent: agent, state: .unknown) }, directory: directory, installedAgents: { _ in [.claudeCode, .codex] }, makeRunner: { _, _, _ in runner })
        let attributes = try FileManager.default.attributesOfItem(atPath: first.socketPath)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        _ = await first.runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "Working")))
        await waitUntil("first server owns an active turn") { (try? await fixture.store.session(id: fixture.session.id)?.state) == .running }
        do {
            _ = try await ServerDaemon.start(authentication: { agent, _, _ in .init(agent: agent, state: .unknown) }, directory: directory)
            Issue.record("A second server acquired the same data directory")
        } catch { #expect(error.localizedDescription.contains("already owns")) }
        let state = try await fixture.store.session(id: fixture.session.id)?.state
        #expect(state == .running)
        let client = try await ServerClient.connect(to: .local(directory: directory))
        let reply = try await client.request(ServerRequest(.catalogue))
        if case .catalogue = reply.result {} else { Issue.record("First server lost its socket") }
        await client.disconnect()
        await first.shutdown()
    }

    @Test func stoppedClaudeTurnDoesNotRequireAResultEvent() async throws {
        let fixture = try await ServerFixture()
        fixture.runner.emitsStopResult.withLock { $0 = false }
        let runtime = fixture.runtime()
        _ = await runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "First")))
        await waitUntil("first prompt starts before stopping") { await fixture.runner.sends.count == 1 }
        _ = await runtime.respond(to: ServerRequest(.stop(sessionID: fixture.session.id)))
        await waitUntil("cancelled state is stored") {
            (try? await fixture.store.session(id: fixture.session.id)?.state) == .cancelled
        }
        let second = await runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "Second")))
        #expect(second.isAccepted)
        await waitUntil("second prompt resumes the queue") { await fixture.runner.sends == ["First", "Second"] }
        await runtime.shutdown()
    }

    @Test func stopWaitsForAnAcceptedSendBeforeSignallingTheRunner() async throws {
        let fixture = try await ServerFixture()
        let runtime = fixture.runtime()
        let send = Task { await runtime.respond(to: ServerRequest(.send(sessionID: fixture.session.id, text: "Starting"))) }
        await waitUntil("send reaches the runner") { await fixture.runner.sends.count == 1 }
        let stopped = await runtime.respond(to: ServerRequest(.stop(sessionID: fixture.session.id)))
        let sent = await send.value
        #expect(stopped.isAccepted)
        #expect(sent.isAccepted)
        #expect(fixture.runner.stops.withLock { $0 } == 1)
        await runtime.shutdown()
    }

    @Test func queuedPromptsRestoreWithoutAConnectedClient() async throws {
        let fixture = try await ServerFixture()
        _ = try await fixture.store.enqueueDelivery(Delivery(targetSessionID: fixture.session.id, body: "Stored before restart"))
        let runtime = fixture.runtime()
        try await runtime.restoreQueuedPrompts()
        await waitUntil("server restores pending delivery") { await fixture.runner.sends == ["Stored before restart"] }
        await runtime.shutdown()
    }

    @Test func uncertainQueuedDeliveryRequiresReviewAndCanBeRemoved() async throws {
        let fixture = try await ServerFixture()
        let delivery = Delivery(targetSessionID: fixture.session.id, body: "Possibly already sent")
        _ = try await fixture.store.enqueueDelivery(delivery)
        try await fixture.store.setSetting("server.delivery." + delivery.id.rawValue, "started")
        let runtime = fixture.runtime()
        try await runtime.restoreQueuedPrompts()
        await waitUntil("uncertain delivery is held") {
            let reply = await runtime.respond(to: ServerRequest(.transcript(sessionID: fixture.session.id, afterSeq: -1)))
            if case .transcript(let value) = reply.result { return value.queueError != nil && value.queuedPrompts.count == 1 }
            return false
        }
        #expect(await fixture.runner.sends.isEmpty)
        let cancelled = await runtime.respond(to: ServerRequest(.cancelQueued(sessionID: fixture.session.id, deliveryID: delivery.id)))
        #expect(cancelled.isAccepted)
        #expect(try await fixture.store.pendingDeliveries(sessionID: fixture.session.id).isEmpty)
        await runtime.shutdown()
    }

    @Test func ownerClosingCrewReportsOnceWithoutResumingPausedParent() async throws {
        let fixture = try await ServerFixture()
        let member = try await fixture.store.upsert(Session(workspaceID: fixture.session.workspaceID, parentSessionID: fixture.session.id, title: "reviewer"))
        let runtime = fixture.runtime()
        #expect(await runtime.respond(to: ServerRequest(.stop(sessionID: fixture.session.id))).isAccepted)
        #expect(await runtime.respond(to: ServerRequest(.closeSession(sessionID: member.id))).isAccepted)
        #expect(await runtime.respond(to: ServerRequest(.closeSession(sessionID: member.id))).isAccepted)
        let reports = try await fixture.store.pendingDeliveries(sessionID: fixture.session.id)
        #expect(reports.count == 1)
        #expect(reports.first?.kind == .report)
        #expect(reports.first?.crewMessage == CrewMessage.stoppedByOwner(name: "reviewer"))
        #expect(await fixture.runner.sends.isEmpty)
        #expect(try await fixture.store.session(id: member.id)?.archivedAt != nil)
        await runtime.shutdown()
    }

    @Test func closingCrewCannotReviveAnArchivedParentConversation() async throws {
        let fixture = try await ServerFixture()
        let member = try await fixture.store.upsert(Session(workspaceID: fixture.session.workspaceID, parentSessionID: fixture.session.id, title: "reviewer"))
        _ = try await fixture.store.update(sessionID: fixture.session.id) { $0.archivedAt = Date() }
        let runtime = fixture.runtime()
        #expect(await runtime.respond(to: ServerRequest(.closeSession(sessionID: member.id))).isAccepted)
        #expect(try await fixture.store.pendingDeliveries(sessionID: fixture.session.id).isEmpty)
        #expect(await fixture.runner.sends.isEmpty)
        await runtime.shutdown()
    }

    @Test func restartCancelsAnArchiveBookedForTheInterruptedTurn() async throws {
        let fixture = try await ServerFixture()
        let key = "server.archive.after-turn." + fixture.session.id.rawValue
        try await fixture.store.setSetting(key, fixture.session.workspaceID?.rawValue)
        let runtime = fixture.runtime()
        try await runtime.restoreQueuedPrompts()
        #expect(try await fixture.store.setting(key) == nil)
        let messages = try await fixture.store.messages(sessionID: fixture.session.id)
        #expect(messages.contains { String(decoding: $0.payload, as: UTF8.self).contains("archive request was cancelled") })
        #expect(try await fixture.store.workspace(id: fixture.session.workspaceID!)?.state == .active)
        await runtime.shutdown()
    }

    @Test func dataDirectoryMustBePrivate() async throws {
        let directory = TestScratch.path("public-server")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
        do {
            _ = try await ServerDaemon.start(authentication: { agent, _, _ in .init(agent: agent, state: .unknown) }, directory: directory)
            Issue.record("Server accepted a public data directory")
        } catch { #expect(error.localizedDescription.contains("700")) }
        #expect(!FileManager.default.fileExists(atPath: ServerDaemon.databasePath(directory: directory)))
    }

    @Test func remoteCommandQuotesPathsAndRefusesSSHOptions() throws {
        let endpoint = ServerEndpoint.ssh(host: "developer@buildbox", executable: "/opt/Bloom's tools/bloom-server", directory: "/tmp/$(touch bad)")
        let proposedLaunch = try endpoint.launch
        let launch = try #require(proposedLaunch)
        #expect(launch.executable == "/usr/bin/ssh")
        #expect(launch.arguments.contains("StrictHostKeyChecking=yes"))
        #expect(launch.arguments.last == "'/opt/Bloom'\\''s tools/bloom-server' 'connect' '--data-dir' '/tmp/$(touch bad)'")
        #expect(throws: ServerFailure.self) {
            _ = try ServerEndpoint.ssh(host: "-oProxyCommand=bad", executable: "/bin/server", directory: "/tmp/data").launch
        }
    }
}

private extension ServerReply {
    var isAccepted: Bool { if case .accepted = result { return true }; return false }
    var failure: String? { if case .failure(let text) = result { return text }; return nil }
}

private struct ServerFixture {
    let directory: String
    let store: Store
    let session: Session
    let runner: ServerTestRunner

    init() async throws {
        directory = TestScratch.unique("server")
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        store = try Store(path: ServerDaemon.databasePath(directory: directory))
        let repo = try await store.upsert(Repo(name: "Fixture", path: directory))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "Fixture", branch: "fixture", path: directory, baseBranch: "main"
        ))
        session = try await store.upsert(Session(workspaceID: workspace.id))
        runner = ServerTestRunner(sessionID: session.id, store: store)
    }

    func runtime(availableAgents: [AgentKind] = [.claudeCode, .codex]) -> ServerRuntime {
        let runner = runner
        return ServerRuntime(store: store, authentication: { agent, _, _ in .init(agent: agent, state: .unknown) }, installedAgents: { _ in availableAgents }, makeRunner: { _, _, _ in runner })
    }
}

private actor ServerTestRunner: SessionRunner {
    nonisolated let agentKind = AgentKind.claudeCode
    nonisolated let terminated = Mutex(false)
    nonisolated let stops = Mutex(0)
    nonisolated let emitsStopResult = Mutex(true)
    nonisolated let sink = EventFanout<AgentEvent>()
    nonisolated var events: AsyncStream<AgentEvent> { sink.stream() }
    var isProcessAlive: Bool { !terminated.withLock { $0 } }
    private(set) var sends: [String] = []
    private(set) var answers = 0
    let sessionID: SessionID
    let store: Store

    init(sessionID: SessionID, store: Store) { self.sessionID = sessionID; self.store = store }

    func send(_ text: String, recording: Data?) async throws {
        sends.append(text)
        _ = try await store.appendNext(sessionID: sessionID, kind: .user, payload: Data(text.utf8))
        _ = try await store.update(sessionID: sessionID) { $0.apply(.turnStarted) }
        try await Task.sleep(for: .milliseconds(20))
    }

    nonisolated func cancelNow() {
        stops.withLock { $0 += 1 }
        if emitsStopResult.withLock({ $0 }) { sink.yield(.result(AgentResult())) } else { Task { await recordStop() } }
    }

    private func recordStop() async {
        _ = try? await store.update(sessionID: sessionID) { $0.apply(.cancelled) }
    }
    nonisolated func terminateNow() { terminated.withLock { $0 = true } }

    func answer(requestID: String, decision: PermissionDecision) async {
        answers += 1
        try? await store.resolvePermissionAsk(id: requestID, decision: decision.storedName)
    }

    func finish() async {
        _ = try? await store.update(sessionID: sessionID) { $0.apply(.turnFinished(isError: false)) }
        sink.yield(.result(AgentResult()))
    }
}
