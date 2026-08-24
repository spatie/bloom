import Foundation

/// Everything a caller has to say to get a workspace with an agent ready to work in it.
///
/// One value rather than eleven arguments, because there are now four routes to a workspace and
/// they had already drifted apart: the create sheet could choose a base branch, a branch name, a
/// backend, a model, an effort and a permission mode; the `bloom://` link, the Services menu and
/// the Shortcuts intent were each hardwired to chat, the default branch and the default model,
/// not by decision but because nobody carried the arguments through. A route that fills in a
/// request cannot quietly lose a field, because the field is still there, holding nil, and nil has
/// a documented meaning.
///
/// The nils are all "apply the ordinary rule", never "we did not think about it":
///
/// - `baseBranch` nil is the project's default branch.
/// - `branch` nil is a slug of the prompt, with the project's `branchPrefix` in front of it.
/// - `name` nil hands the naming to `namer`, and to `Git.title` when that declines.
/// - `controls` nil is the app-wide defaults, applied by `Session.init` as they always were.
///
/// `origin` has no default and no nil. See `WorkspaceOrigin`.
public struct WorkspaceStartRequest: Sendable {
    /// The id the workspace will be stored under.
    ///
    /// Decided by the caller rather than by `cut`, so that a caller can draw the row before the
    /// worktree exists and have the stored row take its place rather than appear beside it. See
    /// `PendingWorkspace`, which is the whole reason this is here. A caller with nothing to draw
    /// leaves it alone and gets a fresh one, exactly as before.
    public var id: WorkspaceID
    public var repo: Repo
    public var prompt: String
    public var baseBranch: String?
    public var branch: String?
    public var name: String?
    /// An existing pull request or branch to open, instead of cutting a new branch.
    ///
    /// Nil is the route Bloom has always had: a branch named after the prompt, cut from
    /// `baseBranch`. Non nil replaces all three of those decisions at once, because a checkout
    /// brings its own branch, its own name and, in the case of a pull request, its own base. See
    /// `WorkspaceCheckout`.
    public var checkout: WorkspaceCheckout?
    public var controls: ComposerControls?
    /// Who asked. Stated by every caller, because the initialiser gives it no default: a route
    /// that an agent can reach and that forgot to say so would hand the workspace to the owner and
    /// leave the agent with no authority over what it just made.
    public var origin: WorkspaceOrigin
    /// Whether to open a chat in the new worktree.
    ///
    /// False for a workspace that opens on a terminal, where there is nobody to send an opening
    /// message to. It is not a mode: the workspace can gain a chat later from the `+` menu like
    /// any other. See `WorkspaceStartMode`.
    public var opensSession: Bool
    /// Whether `start` runs the setup script itself, and waits for it.
    ///
    /// False for the app, which runs it through `WorkspaceModel` so the output streams into the
    /// transcript, a failure raises the one sentence every route says about a failed setup, and
    /// the whole thing can be cancelled by an archive. True for a caller with no window to stream
    /// into, which wants the worktree to have its dependencies installed by the time `start`
    /// returns.
    public var runsSetup: Bool

    public init(
        id: WorkspaceID = .new(),
        repo: Repo,
        prompt: String,
        origin: WorkspaceOrigin,
        baseBranch: String? = nil,
        branch: String? = nil,
        name: String? = nil,
        checkout: WorkspaceCheckout? = nil,
        controls: ComposerControls? = nil,
        opensSession: Bool = true,
        runsSetup: Bool = false
    ) {
        self.id = id
        self.repo = repo
        self.prompt = prompt
        self.origin = origin
        self.baseBranch = baseBranch
        self.branch = branch
        self.name = name
        self.checkout = checkout
        self.controls = controls
        self.opensSession = opensSession
        self.runsSetup = runsSetup
    }
}

/// What came of a `WorkspaceStartRequest`.
public struct StartedWorkspace: Sendable {
    public var workspace: Workspace
    /// The chat that was opened, or nil when the request did not ask for one.
    public var session: Session?
    /// The codename `namer` handed out, when it did.
    ///
    /// The caller's cue to start automatic naming, which `start` deliberately does not do itself:
    /// naming asks a model, takes seconds, and nothing waits for it. The workspace is on disk, the
    /// setup script is going and the first turn has been sent long before the answer lands.
    public var placeholder: String?
    /// Whether the setup script succeeded, or nil when this request did not run it.
    ///
    /// Three answers rather than a bool, because "setup failed" and "nobody ran setup" are
    /// different things to tell a caller, and a false meaning either of them is how a workspace
    /// with no dependencies installed gets reported as fine.
    public var setupSucceeded: Bool?

    public init(
        workspace: Workspace,
        session: Session? = nil,
        placeholder: String? = nil,
        setupSucceeded: Bool? = nil
    ) {
        self.workspace = workspace
        self.session = session
        self.placeholder = placeholder
        self.setupSucceeded = setupSucceeded
    }
}

extension WorkspaceManager {
    /// The one way a workspace is started, whoever is asking.
    ///
    /// This exists because opening a workspace from outside the app has to execute the same code
    /// as opening one from the sheet, and it did not. The sheet was the only route that carried a
    /// base branch, a branch name, a backend, a model, an effort or a permission mode; the
    /// `bloom://` link and the Services menu called the same method with everything after `prompt`
    /// left at its default; and the Shortcuts intent did not call it at all. It built a `bloom://`
    /// URL, opened it, and then polled the database for up to sixty seconds looking for a row it
    /// had not seen before, because a URL is one way and there was nothing to return. Two
    /// Shortcuts creating a workspace in one project at the same second could each claim the
    /// other's row.
    ///
    /// So the orchestration lives here, in the core, where the suite can reach it: the worktree,
    /// the chat, the choices written onto it, and the setup script when the caller has nobody to
    /// stream it to.
    ///
    /// **It throws.** Every route used to end in an alert, which is a fine answer for a person
    /// standing in front of the sheet and no answer at all for a caller with no window. What went
    /// wrong is now the caller's to report, in whatever way its caller can hear.
    ///
    /// What it deliberately does NOT do, because all of it is about a window rather than about a
    /// workspace: select the new row, reload the sidebar, record which tab it opens on, adopt
    /// attachments staged before the worktree existed, animate anything, or start the model that
    /// names it. `AppModel.adopt` is where those live.
    ///
    /// - Parameter namer: asked for a codename when the request did not carry a name, and allowed
    ///   to decline. It is a closure because whether to name a workspace automatically depends on
    ///   a preference and on whether the CLI is installed, and on which codenames are already in
    ///   use, none of which this layer should be reaching for.
    /// - Parameter setupOutput: each line the setup script writes, when `runsSetup` is true.
    public func start(
        _ request: WorkspaceStartRequest,
        namer: @Sendable () async -> String? = { nil },
        setupOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> StartedWorkspace {
        // Decided before the worktree exists, so the row never appears under one name and changes
        // to another in the same breath. A checkout is never named by a model: a pull request and
        // a branch each already have a name somebody chose, and a review workspace called after a
        // sea would be one more thing to translate back.
        let placeholder = request.name == nil && request.checkout == nil ? await namer() : nil

        let workspace = try await createWorkspace(
            id: request.id,
            repo: request.repo,
            prompt: request.prompt,
            name: request.name ?? placeholder,
            branch: request.branch,
            baseBranch: request.baseBranch,
            origin: request.origin,
            checkout: request.checkout
        )

        var session: Session?
        if request.opensSession {
            let controls = request.controls
            let opened = try await store.upsert(Session(
                workspaceID: workspace.id,
                // Not the prompt. The WORKSPACE is named after the work, by `namer` above and
                // by `Git.title` when that declines; the tab over the conversation is furniture
                // and says what it is. Naming both from the same sentence gave one workspace two
                // names, a real one in the sidebar and a fragment of a prompt in the strip. See
                // `PaneNaming`.
                title: PaneNaming.chat,
                model: controls?.model ?? AppDefaults.fallbackModel,
                effort: controls?.effort ?? AppDefaults.fallbackEffort,
                // A request chooses a backend for the first chat and for no other. Every chat
                // opened in this worktree afterwards picks its own, and two chats in one worktree
                // can be on different ones.
                agentKind: controls?.agentKind ?? .claudeCode,
                permissionMode: controls?.permissionMode ?? AppDefaults.fallbackPermissionMode
            ))
            // Fast mode and the output style have no column. Writing them here also marks the
            // session settled, which is what stops the composer's first-open defaults from
            // overruling any of the four the moment the workspace is opened.
            await controls?.store(sessionID: opened.id, in: store)
            session = opened
        }

        var setupSucceeded: Bool?
        if request.runsSetup {
            // A machine with no free block left is not a reason to refuse to run setup. The script
            // simply gets no port to bind, which it can decide for itself what to do about.
            let port = (try? PortAllocator.allocate(taken: [])) ?? 0
            setupSucceeded = await runSetup(
                workspace: workspace, repo: request.repo, port: port
            ) { line in
                setupOutput?(line)
            }
        }

        return StartedWorkspace(
            workspace: workspace,
            session: session,
            placeholder: placeholder,
            setupSucceeded: setupSucceeded
        )
    }
}
