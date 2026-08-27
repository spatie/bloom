import BloomCore

/// Making a workspace, starting one, and carrying one on after its pull request is merged.
///
/// The first half is the ordinary route in: `createWorkspace` cuts the worktree,
/// `startWorkspace` is the same thing said by an agent through the bridge, and `adopt` is what
/// the app has to do once either of them has produced a workspace.
///
/// The second half exists because a merged workspace used to be a dead end. Continuing keeps the
/// installed dependencies, the copied `.env`, the dev servers on their ports and above all the
/// agent's session, and changes only the thing that is genuinely finished, which is the branch.
/// The decision itself is `ContinuationGate` in BloomCore and is the only thing allowed to say
/// yes; what is here is the app work either side of it.

extension AppModel {
    /// Creates the worktree, selects it, kicks off setup, and sends the first prompt once setup
    /// finishes. The whole flow is one call because that is how it reads to the user.
    ///
    /// Thin on purpose. Everything about the workspace itself is `WorkspaceManager.start`, in the
    /// core, where it can be tested; what is left here is a request, an alert, and the part of the
    /// tail that is genuinely about this window. Opening a workspace from outside the app has to
    /// run the same code as opening one from the sheet, and until this was split it could not,
    /// because the code was on the main actor in a target nothing else can reach.
    ///
    /// `opensWith` decides the starting layout, not a mode: see `WorkspaceStartMode`. A terminal
    /// or browser workspace skips the session and the opening message, because there is nobody to
    /// send one to, and names its own branch since there is no task to derive one from.
    ///
    /// `controls` are the model, effort, permission mode and fast mode chosen in the create
    /// sheet's composer footer. Nil everywhere else, which keeps those callers exactly as they
    /// were.
    ///
    /// `staged` are attachments written before this worktree existed. They are moved into it here,
    /// between the worktree being cut and the opening turn being handed over, because that is the
    /// only moment at which the destination exists and nothing is reading the prompt yet.
    @discardableResult
    func createWorkspace(
        in repo: Repo,
        prompt: String,
        baseBranch: String? = nil,
        opensWith: WorkspaceStartMode = .chat,
        branch: String? = nil,
        controls: ComposerControls? = nil,
        staged: StagedAttachments? = nil,
        checkout: WorkspaceCheckout? = nil
    ) async -> Workspace? {
        do {
            return try await startWorkspace(
                in: repo, prompt: prompt, baseBranch: baseBranch, opensWith: opensWith,
                branch: branch, controls: controls, staged: staged, checkout: checkout
            )
        } catch {
            // Diagnosed rather than reported. `error.readableMessage` on a `ShellError` is the git
            // command line, its exit status and its stderr, and a project whose folder had stopped
            // being a checkout put up "`git for-each-ref --format=%(refname:short) refs/heads`
            // exited 128: fatal: not a git repository". That names no project, says nothing to do,
            // and hands the reader a command they never ran. See `WorkspaceTrouble`.
            let trouble = await WorkspaceTrouble.creating(
                error,
                project: repo.name,
                projectPath: repo.path,
                baseBranch: baseBranch ?? repo.defaultBranch
            )
            alert = BloomAlert(title: "Could not create the workspace", message: trouble.sentence)
            return nil
        }
    }

    /// The same thing, for a caller that can be told what went wrong.
    ///
    /// An alert is the right answer for somebody standing in front of the sheet and no answer at
    /// all for a Shortcut, which has its own place to show a sentence and had nowhere to read one
    /// from. So the alert is one line in the wrapper above and everything else is here, shared,
    /// rather than a second copy of the flow written for callers without a window.
    @discardableResult
    func startWorkspace(
        in repo: Repo,
        prompt: String,
        baseBranch: String? = nil,
        opensWith: WorkspaceStartMode = .chat,
        branch: String? = nil,
        controls: ComposerControls? = nil,
        staged: StagedAttachments? = nil,
        select: Bool = true,
        /// Who asked. Defaulted to the owner because every caller but one is the owner, and
        /// spelled out by the one that is not. See `WorkspaceOrigin`.
        origin: WorkspaceOrigin = .user,
        /// Overrides the name Bloom would derive. Only the bridge passes one; the sheet lets the
        /// namer do its job.
        name: String? = nil,
        /// An existing pull request or branch to open instead of cutting a branch. See
        /// `WorkspaceCheckout`.
        checkout: WorkspaceCheckout? = nil
    ) async throws -> Workspace {
        guard let manager else { throw AppNotReady.stillStartingUp }
        isCreatingWorkspace = true
        defer { isCreatingWorkspace = false }

        // What the task says without the files named in it. The prompt carries its attachments as
        // paths in the sentence now, and every reader below this line is naming something after
        // what was asked for: a workspace called `9JVKW4` after the folder a screenshot was copied
        // into would be a name nobody could recognise.
        //
        // `prompt` is the draft as it was written, files and all. The sheet used to strip them
        // before handing it over, which named the workspace correctly and left the agent reading a
        // sentence about screenshots it had never been told about. See `WorkspaceStartAttachments`.
        let stagedPaths = staged?.attachments.map(\.path) ?? []
        let spoken = WorkspaceStartAttachments.spoken(prompt, staged: stagedPaths)

        // A caller with no controls gets the ones the owner actually chose, not the built-in
        // fallback. The sheet and the bridge both pass controls; a `bloom://` link, the Services
        // menu and a Shortcut do not, and those used to open a chat on `opus` whatever the Models
        // screen said. `ComposerView.prepare` corrected it when the workspace was opened, which
        // is a race the opening turn can win: a workspace created in the background and never
        // looked at would run its first turn on a model nobody picked.
        let effectiveControls: ComposerControls
        if let controls {
            effectiveControls = controls
        } else {
            effectiveControls = try await resolvedControls(for: repo)
        }

        // Whether to ask a model for a name at all. Read here rather than inside the closure
        // below, because it is two facts about this machine that only the main actor holds: the
        // preference, and whether the CLI is installed.
        // Never for a checkout. A pull request arrives with a title and a number, and a review
        // workspace that renamed itself after the task typed into the sheet would hide which pull
        // request it is.
        let wantsAName = checkout == nil
            && shouldNameAutomatically(name: nil, prompt: spoken, opensWith: opensWith)

        // The sea this workspace wears while the model thinks of a real name. Claimed here,
        // before `manager.start`, because its slug is about to be the branch and the branch has
        // to exist before the worktree is cut. `OceanCatalog.shouldClaim` holds the rule about
        // who gets one, in the core where it is tested. A nil store or an exhausted claim falls
        // back to the plant placeholder below, exactly as before.
        let pick: OceanPick?
        if OceanCatalog.shouldClaim(
            userSuppliedName: name ?? checkout?.workspaceName,
            userSuppliedBranch: branch,
            isChatWorkspace: opensWith == .chat,
            wantsAutomaticName: wantsAName,
            // A workspace with no agent, started with nothing written, has no other source of a
            // name: no turn is sent, so no model is asked, and there is no sentence to slug a
            // branch out of. The sea is both, and it is the name for good rather than a
            // placeholder.
            hasTask: !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ) {
            pick = try? await store?.claimOcean()
        } else {
            pick = nil
        }

        // The sea's slug under the project's branch prefix, by literally the rule
        // `nameAutomatically` applies to a suggested branch rather than by a copy of it: this used
        // to write the join and the check out again, under a comment claiming they could not
        // disagree. Nil hands the branch back to the mechanical slug of the prompt.
        //
        // Off the main actor, like `resolvedControls` above and for the same reason: the load
        // reads and parses every settings file this project answers to, and this line sits on the
        // frame that is dismissing the create window.
        let seaBranch: String?
        if let pick {
            let path = repo.path
            let prefix = await Task.detached(priority: .userInitiated) {
                SettingsLoader.load(repo: path).branchPrefix
            }.value
            seaBranch = WorkspaceNaming.prefixedBranch(pick.ocean.slug, prefix: prefix)
        } else {
            seaBranch = nil
        }

        // The name settled before anything is cut, rather than inside the closure `manager.start`
        // calls, and the reason is the row that has to be drawn while the cutting happens.
        //
        // `start` asks its namer only when the request carries no name and no checkout, so the
        // same two conditions decide here whether there is a codename at all. Resolving it up
        // here changes nothing about what `start` does with it: the closure below hands back this
        // value, `start` still reports it as `placeholder`, and `adopt` still starts the automatic
        // rename against it.
        // Asked as "does an agent run here" rather than as "is this a terminal", which is what it
        // said while terminal was the only answer. A browser workspace has no turn either, so it
        // has to settle its own name here for the same reason and by the same rule.
        let suppliedName = name ?? (opensWith.runsAnAgent
            ? nil
            : WorkspaceStartPlan.terminalName(
                userSuppliedBranch: branch, claimedSea: pick?.ocean.name
            ))
        let placeholder: String?
        if suppliedName == nil, checkout == nil, wantsAName {
            // The AI rename compares against the exact placeholder handed over, so the sea's name
            // goes through here rather than being written on the row afterwards.
            if let sea = pick?.ocean.name {
                placeholder = sea
            } else {
                placeholder = await placeholderName()
            }
        } else {
            placeholder = nil
        }

        // The row goes up now, under the name the stored row is about to carry, and comes down in
        // `reload` when that row arrives. `WorkspaceStartPlan.name` is the same call
        // `WorkspaceManager` makes, so the two cannot say different things. See `PendingWorkspace`.
        let id = WorkspaceID.new()
        showPending(PendingWorkspace(
            id: id,
            repoID: repo.id,
            name: WorkspaceStartPlan.name(
                supplied: suppliedName ?? placeholder, checkout: checkout, prompt: spoken
            )
        ))

        let request = WorkspaceStartRequest(
            id: id,
            repo: repo,
            prompt: spoken,
            // Almost always the owner: the sheet, a `bloom://` link, the Services menu and a
            // Shortcut all land here. The exception is the bridge, which passes `.agent` so the
            // row records who asked and the sidebar can show the lineage.
            origin: origin,
            baseBranch: baseBranch,
            // The claimed sea's slug when there is one, so the branch and the name tell the same
            // story. `Git.uniqueBranch` still suffixes a collision with an earlier voyage.
            branch: branch ?? seaBranch,
            // A workspace with no agent is named after the branch the user typed, or after the
            // sea it just claimed when nothing was typed at all. Either way the name is settled above
            // rather than left to the namer, because nothing is going to be asked: passing a name
            // is also what stops `start` returning a placeholder and so what stops `adopt`
            // kicking off an automatic rename with no first turn to read.
            name: suppliedName,
            checkout: checkout,
            controls: effectiveControls,
            opensSession: opensWith == .chat,
            // The app runs setup itself, through `WorkspaceModel`, so the output streams into the
            // transcript, a failure raises the one sentence every route says about a failed setup,
            // and an archive can cancel it. See `adopt`.
            runsSetup: false
        )

        // Nil declines, and the workspace keeps the title git would have given it. The closure is
        // still how `start` learns the codename, so that it stays the one place deciding whether
        // there is one; what it hands back was worked out above rather than here.
        let started: StartedWorkspace
        do {
            started = try await manager.start(request) { placeholder }
        } catch {
            // The only way out with the row still up. Everything past this line has a stored
            // workspace behind it, and `reload` retires the pending row against that.
            forgetPending(id)
            throw error
        }

        await adopt(started, repo: repo, prompt: spoken, opensWith: opensWith, select: select)

        // Only a first discovery says anything. `OceanPick.notice` is nil for a repeat voyage,
        // which is deliberately not worth a banner.
        if let notice = pick?.notice {
            self.notice = BloomNotice(message: notice)
        }

        // Said out loud, because this is a preference the owner set that Bloom has just undone,
        // and the workspace that undid it can have been asked for by an agent on the bridge with
        // nobody watching. A banner is exactly what `BloomNotice` is for: something the app did
        // that the user did not ask for and should still know about.
        //
        // After the sea rather than before it, so it wins when a first voyage and a project
        // coming back land together. One of the two is a project changing state under the reader
        // and the other is decoration.
        if started.projectCameBack {
            self.notice = BloomNotice(
                message: "\(repo.name) is back in Bloom's sidebar. It was hidden, and this "
                    + "workspace has just been added to it."
            )
        }

        // The files come across whichever mode asked for the workspace, and the sentence names
        // whichever of them arrived. Both halves are `WorkspaceStartAttachments`, in the core,
        // because an attachment is only correct when the two agree and neither is visible from
        // the other's side.
        let arrived: Set<String> = staged.map {
            WorkspaceStartAttachments
                .adopt(stagedPaths, from: $0.directory, into: started.workspace.path)
        } ?? []
        let opening = WorkspaceStartAttachments.opening(
            prompt, staged: stagedPaths, arrived: arrived, isChatWorkspace: opensWith == .chat
        )

        // Setup runs whether or not there is an agent turn to follow it. Only the turn is skipped
        // for a terminal workspace.
        await model(for: started.workspace).startSetupThenSend(prompt: opening, repo: repo)
        return started.workspace
    }

    /// The model, effort and permission mode the owner has actually chosen for this project.
    ///
    /// The same resolution the composer and the create window do, so a workspace created without a
    /// window agrees with one created from the sheet rather than falling back to the built-in.
    /// Repository settings first, then the Settings screen, then a machine-wide file. See
    /// `ComposerDefaults.resolve`.
    private func resolvedControls(for repo: Repo) async throws -> ComposerControls {
        guard let store else { return ComposerControls() }

        let appDefaults = await AppDefaults.load(from: store)
        let repoSettings = await Task.detached(priority: .userInitiated) {
            SettingsLoader.load(repo: repo.path)
        }.value
        let resolved = ComposerDefaults.resolve(repo: repoSettings, app: appDefaults)

        // The backend is left at its default rather than derived from the model. Nothing in the
        // tree maps one to the other: the composer takes it from the picker press, because
        // choosing a model out of the Codex section IS choosing Codex, and there is no rule that
        // reads it back off the name. Guessing here would be inventing that rule where the
        // consequence of getting it wrong is a chat on a backend nobody chose.
        return ComposerControls(
            model: resolved.model,
            effort: resolved.effort,
            permissionMode: resolved.permissionMode,
            isFastMode: appDefaults.fastMode
        )
    }

    /// What this window does about a workspace that has just been started.
    ///
    /// The tail of `createWorkspace`, named and separated so that a caller which is not the sheet
    /// can decide how much of it applies. `select` is the whole reason: taking the selection is
    /// right when the owner just pressed Create and wrong when a workspace appears while they are
    /// typing somewhere else.
    ///
    /// Most of what is here is genuinely about a window: which row is selected, which tab the
    /// workspace opens on, which chat is in front, and the model that will rename it.
    ///
    /// `reload` stays, and it is one of the four left in the app now that the store publishes its
    /// own changes. The order is the reason: the sidebar has to know the row exists before
    /// anything selects it, and the change feed cannot promise that. It wakes a task, which reads
    /// the store, which lands some milliseconds after this line. Selecting a workspace the list
    /// has never heard of leaves the window on a row that is not there, and the observer's reload
    /// arriving afterwards is a jump rather than a fix. Every deleted `reload` was one whose
    /// caller did not care when the list caught up. This one does.
    func adopt(
        _ started: StartedWorkspace,
        repo: Repo,
        prompt: String,
        opensWith: WorkspaceStartMode,
        select: Bool
    ) async {
        await reload()

        // Nothing waits for this: the worktree exists and the first turn goes out long before a
        // model has decided what to call it.
        if let placeholder = started.placeholder {
            beginAutomaticNaming(
                workspace: started.workspace,
                repo: repo,
                prompt: prompt,
                placeholder: placeholder
            )
        }

        if select { selection = .workspace(started.workspace.id) }
        WorkspaceStartMode.record(opensWith, workspaceID: started.workspace.id)

        guard let session = started.session else { return }
        let model = model(for: started.workspace)
        await model.reloadSessions()
        model.activeSessionID = session.id
    }

    /// What pressing Continue on a merged pull request came to.
    ///
    /// Three cases rather than an optional sentence, because they read differently to the person
    /// standing in front of the strip. A refusal is Bloom declining on purpose and naming the
    /// condition; a failure is git or the network; and the success carries its own line, because
    /// the branch it cut and the base it cut from are the two things worth confirming.
    enum ContinuationOutcome {
        case continued(WorkspaceContinuation)
        case refused(ContinuationRefusal)
        case failed(String)
    }

    /// Carries a merged workspace on to a fresh branch, in place.
    ///
    /// Merging leaves a workspace at a dead end: the branch is finished, the pull request is
    /// closed, and the only move the app offered was to archive it and start again. Starting again
    /// throws away everything that makes a warmed-up workspace worth having, and none of it is in
    /// git: the installed dependencies, the copied `.env`, the dev servers on their ports, and
    /// above all the agent's session, which has read this codebase and been corrected about it for
    /// an hour. Continuing keeps every one of those and changes only the thing that is genuinely
    /// finished, which is the branch.
    ///
    /// In order: decide, cut, tell the app, tell the agent. The decision is
    /// `ContinuationGate.decide` in BloomCore and is the only thing here allowed to say yes; the
    /// git work is `WorkspaceManager.continueOnNewBranch`; and the turn that goes to the agent is
    /// the `continueAfterMerge` prompt, editable in Settings like every other one.
    ///
    /// The session is NOT restarted. That is the point: a new session would know nothing, which is
    /// the outcome archiving already gives for free.
    func continueAfterMerge(
        _ workspace: Workspace, pullRequest: PullRequest
    ) async -> ContinuationOutcome {
        guard let manager else { return .failed("Bloom is still starting up.") }

        let facts: ContinuationFacts
        do {
            facts = try await manager.continuationFacts(
                workspace: workspace,
                // GitHub's own answer, from the strip the button lives in rather than from a
                // fresh lookup. The strip is the reason the button is on screen at all, so
                // asking again would only introduce a way for the two to disagree.
                isPullRequestMerged: pullRequest.isMerged,
                isAgentRunning: isRunning(workspace)
            )
        } catch {
            return .failed(await trouble(continuing: error, in: workspace).sentence)
        }

        let branch: String
        switch ContinuationGate.decide(facts) {
        case .cut(let cut): branch = cut
        case .refuse(let refusal): return .refused(refusal)
        }

        let continuation: WorkspaceContinuation
        do {
            continuation = try await manager.continueOnNewBranch(
                workspace: workspace, branch: branch
            )
        } catch {
            return .failed(await trouble(continuing: error, in: workspace).sentence)
        }

        await adopt(continuation, pullRequest: pullRequest)
        return .continued(continuation)
    }

    /// Both catches above, so the two sentences cannot drift apart.
    private func trouble(continuing error: any Error, in workspace: Workspace) async -> WorkspaceTrouble {
        await WorkspaceTrouble.continuing(
            error,
            workspace: workspace.name,
            path: workspace.path,
            baseBranch: workspace.baseBranch
        )
    }

    /// Everything the app has to forget or refresh now that the worktree is on another branch.
    private func adopt(_ continuation: WorkspaceContinuation, pullRequest: PullRequest) async {
        let model = model(for: continuation.workspace)

        // The merged pull request belonged to the old branch. Left in place it would keep the
        // strip purple and keep offering the button that has just been pressed, and the poll
        // never clears itself: it ignores a nil answer on purpose, so that a slow network does
        // not make the mark flicker, which means nothing else would ever drop it.
        //
        // One line now that there is one cache. It used to be two, and that pair is what the
        // two-sources-of-truth report was about: the model held its own copy with a 30 second max
        // age beside the shared one's 110, and forgetting one and not the other was a bug waiting
        // for the next caller who only knew about one of them.
        WorkspacePullRequests.shared.forget(continuation.workspace.id)

        // The diff is measured against the base, and the base just moved under it.
        await model.refreshChanges()

        await tellAgent(about: continuation, pullRequest: pullRequest, in: model)
    }

    /// Sends the `continueAfterMerge` prompt into the session that was already running here.
    ///
    /// Silent when there is no session and none can be made. The branch has already moved by this
    /// point and that is the part that matters; an alert about a missing session would be raising
    /// a dialog over the least important half of what was asked for.
    private func tellAgent(
        about continuation: WorkspaceContinuation,
        pullRequest: PullRequest,
        in model: WorkspaceModel
    ) async {
        let template = PromptOverrides().template(for: .continueAfterMerge)
        let render = continuation.render(template: template, pullRequest: pullRequest.number)

        guard let session = await continuationSession(in: model) else { return }
        // The reader pressed a button and a turn is about to stream: put them in front of it.
        model.activeSessionID = session.id
        await model.transcript(for: session).submit(render.text)
    }

    /// The session the continue turn goes to: the one the workspace was already using, or a new
    /// one for a workspace whose agent was never started.
    private func continuationSession(in model: WorkspaceModel) async -> Session? {
        if let session = model.activeSession { return session }
        await model.reloadSessions()
        if let session = model.activeSession { return session }
        return await model.createSession(title: "Continue")
    }
}
