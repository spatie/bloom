import Testing
import Foundation
@testable import BloomCore

/// Starting a workspace, all the way through, against a real git repository.
///
/// The point of this suite is that this flow can be tested at all. It used to live in
/// `AppModel.createWorkspace`, on the main actor, in the target the test target does not depend
/// on, so the only thing anybody could check about creating a workspace was the worktree. The
/// chat that gets opened, the model and effort written onto it, the marker that stops the
/// composer's defaults overruling them, what happens when the setup script fails, and what a
/// caller with no window is told about any of it were all unreachable.
@Suite("Starting a workspace", .tags(.git), .scratchDirectory)
struct WorkspaceStartTests {
    private func makeManager() async throws -> (repo: TempRepo, registered: Repo, manager: WorkspaceManager, store: Store) {
        let repo = try await TempRepo()
        let store = try makeTestStore("start")
        let manager = WorkspaceManager(store: store)
        let registered = try await manager.addRepository(at: repo.path)
        return (repo, registered, manager, store)
    }

    // MARK: - The worktree and the chat

    @Test("a chat workspace arrives with its worktree, its branch and one session")
    func startsAChat() async throws {
        let (repo, registered, manager, store) = try await makeManager()
        defer { repo.cleanUp() }

        let started = try await manager.start(WorkspaceStartRequest(
            repo: registered, prompt: "Fix the flaky test", origin: .user
        ))

        #expect(started.workspace.branch == "fix-flaky-test")
        #expect(FileManager.default.fileExists(atPath: started.workspace.path))
        #expect(started.workspace.baseBranch == "main")

        let session = try #require(started.session)
        #expect(session.workspaceID == started.workspace.id)
        #expect(try await store.sessions(workspaceID: started.workspace.id).map(\.id) == [session.id])
    }

    /// A workspace that opens on a terminal has nobody to send an opening message to, so there is
    /// no chat to open. It is not locked out of one: the `+` menu can add it later.
    @Test("a workspace that opens no chat has no session")
    func startsWithoutASession() async throws {
        let (repo, registered, manager, store) = try await makeManager()
        defer { repo.cleanUp() }

        let started = try await manager.start(WorkspaceStartRequest(
            repo: registered, prompt: "poke about", origin: .user,
            branch: "scratch", name: "scratch", opensSession: false
        ))

        #expect(started.session == nil)
        #expect(started.workspace.name == "scratch")
        #expect(started.workspace.branch == "scratch")
        #expect(try await store.sessions(workspaceID: started.workspace.id).isEmpty)
    }

    /// The promptless start, all the way through. Nothing is written in the box, so the sea is
    /// carried as the request's `name` and its slug as the branch, and both are final: `start`
    /// asks the namer only when the request left the name open, so nothing renames this later.
    @Test("a terminal workspace started with nothing written takes the name it was handed")
    func startsWithNothingWritten() async throws {
        let (repo, registered, manager, store) = try await makeManager()
        defer { repo.cleanUp() }

        let started = try await manager.start(
            WorkspaceStartRequest(
                repo: registered, prompt: "", origin: .user,
                branch: "coral-sea", name: "Coral Sea", opensSession: false
            ),
            namer: { "Foxglove" }
        )

        #expect(started.workspace.name == "Coral Sea")
        #expect(started.workspace.branch == "coral-sea")
        #expect(started.placeholder == nil)
        #expect(started.session == nil)
        #expect(FileManager.default.fileExists(atPath: started.workspace.path))
        #expect(try await store.sessions(workspaceID: started.workspace.id).isEmpty)
    }

    /// The fallback under the sea, for a machine whose catalogue is spent. A workspace still
    /// arrives, on a branch git accepts, rather than the start failing over a name.
    @Test("nothing written and no name handed over still cuts a worktree")
    func startsWithNothingAtAll() async throws {
        let (repo, registered, manager, store) = try await makeManager()
        defer { repo.cleanUp() }

        let started = try await manager.start(WorkspaceStartRequest(
            repo: registered, prompt: "", origin: .user, opensSession: false
        ))

        #expect(started.workspace.name == "New workspace")
        #expect(started.workspace.branch == "workspace")
        #expect(FileManager.default.fileExists(atPath: started.workspace.path))
        #expect(try await store.sessions(workspaceID: started.workspace.id).isEmpty)
    }

    // MARK: - The choices the sheet used to be the only route to carry

    /// Every one of these was reachable from the create window and from nowhere else. The link, the
    /// Services menu and the Shortcuts intent all opened a chat on the app-wide default model
    /// whatever the caller wanted, and nothing said so.
    @Test("the chosen backend, model, effort and permission mode reach the session row")
    func carriesTheControls() async throws {
        let (repo, registered, manager, store) = try await makeManager()
        defer { repo.cleanUp() }

        let started = try await manager.start(WorkspaceStartRequest(
            repo: registered, prompt: "Do the thing", origin: .user,
            controls: ComposerControls(
                model: "gpt-5-codex", effort: "high", agentKind: .codex,
                permissionMode: .acceptEdits, isFastMode: true, outputStyle: "Concise"
            )
        ))

        let session = try #require(started.session)
        #expect(session.model == "gpt-5-codex")
        #expect(session.effort == "high")
        #expect(session.agentKind == .codex)
        #expect(session.permissionMode == .acceptEdits)

        // The two that have no column, and the marker that stops the composer's first-open
        // defaults overruling all four the moment the workspace is opened.
        #expect(
            try await store.setting(ComposerControls.fastModeKey(sessionID: session.id)) == "1"
        )
        #expect(
            try await store.setting(ComposerControls.outputStyleKey(sessionID: session.id)) == "Concise"
        )
        #expect(
            try await store.setting(ComposerControls.defaultsAppliedKey(sessionID: session.id)) == "1"
        )
    }

    @Test("no controls means the app-wide defaults, and no session is marked settled")
    func fallsBackToTheDefaults() async throws {
        let (repo, registered, manager, store) = try await makeManager()
        defer { repo.cleanUp() }

        let started = try await manager.start(WorkspaceStartRequest(
            repo: registered, prompt: "Do the thing", origin: .user
        ))

        let session = try #require(started.session)
        #expect(session.model == AppDefaults.fallbackModel)
        #expect(session.effort == AppDefaults.fallbackEffort)
        #expect(session.agentKind == .claudeCode)
        // Nothing was chosen, so nothing is settled and the composer's first open still applies
        // whatever the repository and the Settings screen say.
        #expect(
            try await store.setting(ComposerControls.defaultsAppliedKey(sessionID: session.id)) == nil
        )
    }

    @Test("a base branch and a branch name are used as given")
    func usesTheGivenBranches() async throws {
        let (repo, registered, manager, _) = try await makeManager()
        defer { repo.cleanUp() }

        try await Shell.check("git", ["checkout", "-q", "-b", "develop"], cwd: repo.path)
        try repo.write("on-develop.txt", "yes\n")
        try await repo.commit("develop only")
        try await Shell.check("git", ["checkout", "-q", "main"], cwd: repo.path)

        let started = try await manager.start(WorkspaceStartRequest(
            repo: registered, prompt: "Carry on", origin: .user,
            baseBranch: "develop", branch: "chosen/branch"
        ))

        #expect(started.workspace.branch == "chosen/branch")
        #expect(started.workspace.baseBranch == "develop")
        // Cut from develop, so the file only develop has is in the worktree.
        #expect(
            FileManager.default.fileExists(
                atPath: (started.workspace.path as NSString).appendingPathComponent("on-develop.txt")
            )
        )
    }

    // MARK: - Naming

    @Test("the codename the namer hands out is the name the row is created under")
    func usesThePlaceholder() async throws {
        let (repo, registered, manager, _) = try await makeManager()
        defer { repo.cleanUp() }

        let started = try await manager.start(
            WorkspaceStartRequest(repo: registered, prompt: "Fix the flaky test", origin: .user),
            namer: { "Foxglove" }
        )

        #expect(started.workspace.name == "Foxglove")
        // Handed back so the caller can start the model that replaces it, and only then.
        #expect(started.placeholder == "Foxglove")
    }

    /// The namer is allowed to decline, and does whenever the preference is off or the CLI is not
    /// installed. The name is then what a workspace has always been called.
    @Test("a namer that declines leaves the title git would have given it")
    func fallsBackToTheTitle() async throws {
        let (repo, registered, manager, _) = try await makeManager()
        defer { repo.cleanUp() }

        let started = try await manager.start(
            WorkspaceStartRequest(repo: registered, prompt: "Fix the flaky test", origin: .user),
            namer: { nil }
        )

        #expect(started.workspace.name == Git.title(from: "Fix the flaky test"))
        #expect(started.placeholder == nil)
    }

    /// A name the caller supplied is a name somebody chose, so nothing is asked and nothing may
    /// overwrite it later. `placeholder` staying nil is what tells the caller not to start the
    /// automatic rename at all.
    @Test("a name in the request is never handed to the namer")
    func aGivenNameWins() async throws {
        let (repo, registered, manager, _) = try await makeManager()
        defer { repo.cleanUp() }

        let started = try await manager.start(
            WorkspaceStartRequest(
                repo: registered, prompt: "Fix the flaky test", origin: .user, name: "Invoices"
            ),
            namer: { Issue.record("the namer was asked about a workspace that already had a name"); return "Foxglove" }
        )

        #expect(started.workspace.name == "Invoices")
        #expect(started.placeholder == nil)
    }

    // MARK: - Who asked

    @Test("a workspace an agent asked for records which one, and which tool call")
    func recordsTheOrigin() async throws {
        let (repo, registered, manager, store) = try await makeManager()
        defer { repo.cleanUp() }

        let parent = try await manager.start(WorkspaceStartRequest(
            repo: registered, prompt: "The parent", origin: .user
        ))
        let started = try await manager.start(WorkspaceStartRequest(
            repo: registered, prompt: "Do a piece of it",
            origin: .agent(parentWorkspaceID: parent.workspace.id, spawnToolUseID: "toolu_01")
        ))

        #expect(parent.workspace.origin == .user)
        #expect(
            started.workspace.origin
                == .agent(parentWorkspaceID: parent.workspace.id, spawnToolUseID: "toolu_01")
        )
        // And it is on the row, not just on the value that was handed back.
        let stored = try #require(try await store.workspace(id: started.workspace.id))
        #expect(stored.origin.parentWorkspaceID == parent.workspace.id)
        #expect(try await store.countWorkspaces(startedBy: parent.workspace.id) == 1)
    }

    // MARK: - Setup

    /// The app runs setup itself so it can stream the output into the transcript and cancel it on
    /// an archive. A caller with no window has neither, and wants the dependencies installed by
    /// the time this returns.
    @Test("a caller that asks for setup gets it run, and its output")
    func runsSetupWhenAsked() async throws {
        let (repo, registered, manager, store) = try await makeManager()
        defer { repo.cleanUp() }

        try repo.write(".conductor/settings.toml", """
        [scripts]
        setup = '''
        echo installing
        touch installed.txt
        '''
        """)

        let lines = LineCollector()
        let started = try await manager.start(
            WorkspaceStartRequest(
                repo: registered, prompt: "Needs dependencies", origin: .user, runsSetup: true
            ),
            setupOutput: { lines.append($0) }
        )

        #expect(started.setupSucceeded == true)
        #expect(lines.joined.contains("installing"))
        #expect(
            FileManager.default.fileExists(
                atPath: (started.workspace.path as NSString).appendingPathComponent("installed.txt")
            )
        )
        let stored = try #require(try await store.workspace(id: started.workspace.id))
        #expect(stored.setupState == .succeeded)
    }

    /// The number the setup script bound has to be the number the archive script is later handed,
    /// which means it has to be on the row.
    ///
    /// This route allocated a block of its own and told nobody: the script wrote a real port into
    /// a `.env` or a compose file and `workspaces.port` stayed 0, so `archive` read 0 out of the
    /// row and a teardown looking for whatever holds `$BLOOM_PORT` had nothing to look for. See
    /// `WorkspaceManager.ensurePort`, and `WorkspacePortTests` for the column's own rules.
    @Test("the port the setup script is given is the port the row keeps")
    func recordsThePortSetupWasGiven() async throws {
        let (repo, registered, manager, store) = try await makeManager()
        defer { repo.cleanUp() }

        try repo.write(".conductor/settings.toml", """
        [scripts]
        setup = "echo port=$BLOOM_PORT"
        """)

        let lines = LineCollector()
        let started = try await manager.start(
            WorkspaceStartRequest(
                repo: registered, prompt: "Needs a port", origin: .user, runsSetup: true
            ),
            setupOutput: { lines.append($0) }
        )

        let stored = try #require(try await store.workspace(id: started.workspace.id))
        #expect(stored.port >= 3_100)
        #expect(lines.joined.contains("port=\(stored.port)"))
    }

    /// A failed setup is reported, not thrown. The worktree exists, the chat exists, and the
    /// caller has to be able to say both that the workspace is there and that its dependencies are
    /// not. Throwing would leave a real workspace behind an error that reads as if nothing
    /// happened.
    @Test("a setup script that fails is reported rather than thrown")
    func reportsAFailedSetup() async throws {
        let (repo, registered, manager, store) = try await makeManager()
        defer { repo.cleanUp() }

        try repo.write(".conductor/settings.toml", """
        [scripts]
        setup = "exit 3"
        """)

        let started = try await manager.start(WorkspaceStartRequest(
            repo: registered, prompt: "Will not install", origin: .user, runsSetup: true
        ))

        #expect(started.setupSucceeded == false)
        #expect(FileManager.default.fileExists(atPath: started.workspace.path))
        #expect(started.session != nil)
        let stored = try #require(try await store.workspace(id: started.workspace.id))
        #expect(stored.setupState == .failed)
    }

    /// Nil, not false. "Setup failed" and "nobody ran setup" are different things to tell a
    /// caller, and a false meaning either is how a worktree with no dependencies in it gets
    /// reported as fine.
    @Test("a caller that did not ask for setup is told nothing about it")
    func saysNothingAboutSetupItDidNotRun() async throws {
        let (repo, registered, manager, store) = try await makeManager()
        defer { repo.cleanUp() }

        try repo.write(".conductor/settings.toml", """
        [scripts]
        setup = "exit 3"
        """)

        let started = try await manager.start(WorkspaceStartRequest(
            repo: registered, prompt: "Someone else will run it", origin: .user
        ))

        #expect(started.setupSucceeded == nil)
        let stored = try #require(try await store.workspace(id: started.workspace.id))
        #expect(stored.setupState == .pending)
    }

    // MARK: - Errors

    /// Every route used to end in an alert, which is a fine answer for a person standing in front
    /// of the sheet and no answer at all for a caller with no window.
    @Test("a repository that is not there throws rather than raising an alert")
    func throwsWhenTheRepositoryIsGone() async throws {
        let (repo, registered, manager, _) = try await makeManager()
        repo.cleanUp()

        await #expect(throws: (any Error).self) {
            try await manager.start(WorkspaceStartRequest(
                repo: registered, prompt: "Nothing to cut from", origin: .user
            ))
        }
    }

    // MARK: - Two at once

    /// The same race `WorktreeCutQueue` closes, through the seam an agent will actually use.
    @Test("two starts at the same moment both come back whole")
    func twoStartsAtOnce() async throws {
        let (repo, registered, manager, store) = try await makeManager()
        defer { repo.cleanUp() }

        let started = try await withThrowingTaskGroup(of: StartedWorkspace.self) { group in
            for index in 0..<3 {
                group.addTask {
                    try await manager.start(WorkspaceStartRequest(
                        repo: registered, prompt: "Fix the flaky test",
                        origin: .agent(
                            parentWorkspaceID: WorkspaceID("parent"), spawnToolUseID: "toolu_\(index)"
                        )
                    ))
                }
            }
            var all: [StartedWorkspace] = []
            for try await one in group { all.append(one) }
            return all
        }

        #expect(Set(started.map(\.workspace.branch)).count == 3)
        #expect(started.compactMap(\.session).count == 3)
        #expect(try await store.countWorkspaces(startedBy: WorkspaceID("parent")) == 3)
    }
}

/// The read-and-clear hint about which tab a new workspace opens on.
///
/// It read and wrote `UserDefaults.standard` directly, while the sibling `remembered(raw:)` takes
/// a raw string precisely so the decision can be pinned, and eight other core types take a
/// `defaults:`. So this one was untestable, and testing it as it stood would have written into
/// the owner's own `be.spatie.bloom` domain, which is the one thing the house rules say never to
/// touch.
@Suite("Which tab a new workspace opens on")
struct WorkspaceOpeningTabTests {
    private func scratchDefaults() -> UserDefaults {
        let suite = "bloom.tests.startmode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Only a start with no agent leaves anything behind. A chat one is the ordinary case and the
    /// centre column's own default, so writing a key for it would be a key per workspace ever
    /// created, forever, saying what would have happened anyway.
    @Test("only a start that is not a chat records anything")
    func onlyAgentlessStartsRecord() {
        let defaults = scratchDefaults()
        let id = WorkspaceID("w1")

        WorkspaceStartMode.record(.chat, workspaceID: id, defaults: defaults)
        #expect(defaults.object(forKey: WorkspaceStartMode.defaultsKey(workspaceID: id)) == nil)

        WorkspaceStartMode.record(.terminal, workspaceID: id, defaults: defaults)
        #expect(defaults.string(forKey: WorkspaceStartMode.defaultsKey(workspaceID: id)) == "terminal")

        WorkspaceStartMode.record(.browser, workspaceID: id, defaults: defaults)
        #expect(defaults.string(forKey: WorkspaceStartMode.defaultsKey(workspaceID: id)) == "browser")
    }

    /// The reason the flag became a value. A `Bool` could ask for the one tab there was a case
    /// for, and the sheet now offers three, so what comes back has to say which.
    @Test("the hint says which tab, not whether")
    func hintSaysWhich() {
        for mode in [WorkspaceStartMode.terminal, .browser] {
            let defaults = scratchDefaults()
            let id = WorkspaceID("w1")
            WorkspaceStartMode.record(mode, workspaceID: id, defaults: defaults)

            #expect(WorkspaceStartMode.consumeOpeningTab(workspaceID: id, defaults: defaults) == mode)
        }
    }

    /// And the pane each of them names, because the centre column opens what this says and a
    /// browser start that opened a shell would be the same bug the hint was written to fix.
    @Test("each mode names the pane it opens")
    func modesNameTheirPane() {
        #expect(WorkspaceStartMode.chat.pane == .chat)
        #expect(WorkspaceStartMode.terminal.pane == .terminal)
        #expect(WorkspaceStartMode.browser.pane == .browser)
    }

    /// Reading clears it, so re-selecting the workspace later does not keep forcing a tab in
    /// front of whatever the user has since arranged. That is the whole behaviour and it was
    /// resting on nothing.
    @Test("the hint answers exactly once")
    func answersExactlyOnce() {
        let defaults = scratchDefaults()
        let id = WorkspaceID("w1")
        WorkspaceStartMode.record(.browser, workspaceID: id, defaults: defaults)

        #expect(WorkspaceStartMode.consumeOpeningTab(workspaceID: id, defaults: defaults) == .browser)
        #expect(WorkspaceStartMode.consumeOpeningTab(workspaceID: id, defaults: defaults) == nil)
        #expect(defaults.object(forKey: WorkspaceStartMode.defaultsKey(workspaceID: id)) == nil)
    }

    @Test("a workspace nobody recorded anything for opens on its chat")
    func unknownWorkspacesOpenOnChat() {
        #expect(WorkspaceStartMode.consumeOpeningTab(
            workspaceID: WorkspaceID("never-seen"), defaults: scratchDefaults()
        ) == nil)
    }

    /// A value written by a version that knows a mode this one does not. Nothing here can honour
    /// it, and a key nothing can honour is one to clear rather than to read again on every open.
    @Test("an unreadable hint is nothing to do, and is cleared")
    func unreadableIsCleared() {
        let defaults = scratchDefaults()
        let id = WorkspaceID("w1")
        defaults.set("notes", forKey: WorkspaceStartMode.defaultsKey(workspaceID: id))

        #expect(WorkspaceStartMode.consumeOpeningTab(workspaceID: id, defaults: defaults) == nil)
        #expect(defaults.object(forKey: WorkspaceStartMode.defaultsKey(workspaceID: id)) == nil)
    }

    /// The build before this one wrote a `Bool` under another key. A workspace cut as a terminal
    /// and not opened before the update landed would otherwise open on a chat, and its `true`
    /// would sit in the defaults for good with nothing left that reads it.
    @Test("a terminal recorded by the previous build is still honoured, once")
    func legacyFlagIsHonoured() {
        let defaults = scratchDefaults()
        let id = WorkspaceID("w1")
        defaults.set(true, forKey: WorkspaceStartMode.legacyTerminalKey(workspaceID: id))

        #expect(WorkspaceStartMode.consumeOpeningTab(workspaceID: id, defaults: defaults) == .terminal)
        #expect(WorkspaceStartMode.consumeOpeningTab(workspaceID: id, defaults: defaults) == nil)
        #expect(defaults.object(
            forKey: WorkspaceStartMode.legacyTerminalKey(workspaceID: id)
        ) == nil)
    }

    /// One key per workspace, so consuming one cannot answer for another.
    @Test("two workspaces do not share the hint")
    func workspacesDoNotShare() {
        let defaults = scratchDefaults()
        WorkspaceStartMode.record(.terminal, workspaceID: WorkspaceID("a"), defaults: defaults)

        #expect(WorkspaceStartMode.consumeOpeningTab(
            workspaceID: WorkspaceID("b"), defaults: defaults
        ) == nil)
        #expect(WorkspaceStartMode.consumeOpeningTab(
            workspaceID: WorkspaceID("a"), defaults: defaults
        ) == .terminal)
    }
}
