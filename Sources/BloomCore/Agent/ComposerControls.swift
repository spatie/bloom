import Foundation

/// Everything the composer's footer pickers choose about the next turn, as a value.
///
/// It exists because the footer now has two callers and only one of them has a `Session` to write
/// to. In a conversation these four live on the session row; in the create window the session has
/// not been made yet, and the same four have to be carried from the sheet into the row that gets
/// made. Naming them once means the footer is written against the choices rather than against
/// where they happen to be stored, and neither caller has to invent its own arrangement of
/// pickers.
///
/// In the core, not beside the footer that draws it, and it lived beside the footer until
/// `WorkspaceStartRequest` needed to carry it. The core cannot see the view layer, so while this
/// was a view-layer type `AgentRunner` had to state the two settings keys below a second time and
/// a test in the suite pinned the two copies together. There is one copy now.
///
/// Fast mode and the output style are in here with the columns even though neither has one on
/// `Session`. They are two of the things the footer offers, the user does not know or care which
/// of them SQLite holds, and leaving them out is what would make this a partial answer.
public struct ComposerControls: Equatable, Sendable {
    public var model: String
    public var effort: String
    /// Which CLI runs the chat. Not a picker of its own: choosing a model out of the Codex section
    /// is choosing Codex, because a model already names its backend and a second menu saying the
    /// same thing would be a second thing to keep in step.
    ///
    /// **Moving it moves the permission mode with it, and that is the invariant this type now
    /// holds.** Codex has no Plan row and Claude Code has no Approve for me, and a chat left
    /// holding the other one's mode is in a mode nothing implements: the picker draws no tick,
    /// the row says one thing and the wire carries another. It used to be arranged by hand at the
    /// places a backend or a mode is set, and two of those were not doing it: the bridge's own
    /// workspace start, and the app-wide "start in plan mode" default, which is chosen in Settings
    /// long before any backend is. See `PermissionMode.nearest(on:)` for where each one lands.
    public var agentKind: AgentKind {
        didSet { permissionMode = permissionMode.nearest(on: agentKind) }
    }
    /// The mode, which can never be one this backend does not have. Assigning one this backend
    /// has no row for lands it on the nearest mode that backend does have, by the same rule the
    /// line above uses. Writing inside a `didSet` does not run the observer again, so the two
    /// cannot chase each other.
    public var permissionMode: PermissionMode {
        didSet { permissionMode = permissionMode.nearest(on: agentKind) }
    }
    public var isFastMode: Bool
    /// How the agent is asked to write, by name. `OutputStyle.defaultName` for "leave it alone",
    /// which is what a session is until somebody picks something else.
    public var outputStyle: String
    /// How large a Codex chat tells its server the model's context window is, in tokens, or
    /// `CodexContextWindow.modelDefault` for whatever Codex's own catalogue says. Ignored on
    /// every other backend, which is why the picker is not drawn there. See `CodexContextWindow`.
    public var codexContextWindow: Int
    /// Whether this chat has a worktree behind it. False is Ask Bloom, and it is here rather than
    /// left to the view because it changes what the permission menu has to say. See
    /// `permissionModeNote`.
    public var hasWorktree: Bool

    public init(
        model: String = AppDefaults.fallbackModel,
        effort: String = AppDefaults.fallbackEffort,
        agentKind: AgentKind = .claudeCode,
        permissionMode: PermissionMode = AppDefaults.fallbackPermissionMode,
        isFastMode: Bool = false,
        outputStyle: String = OutputStyle.defaultName,
        codexContextWindow: Int = CodexContextWindow.modelDefault,
        hasWorktree: Bool = true
    ) {
        self.model = model
        self.effort = effort
        self.agentKind = agentKind
        // Through the rule rather than straight in. A property observer does not run during
        // initialisation, so the one place the invariant above could still be broken is the
        // initialiser, and every value of this type is made here.
        self.permissionMode = permissionMode.nearest(on: agentKind)
        self.isFastMode = isFastMode
        self.outputStyle = outputStyle
        self.codexContextWindow = codexContextWindow
        self.hasWorktree = hasWorktree
    }

    public init(
        session: Session,
        isFastMode: Bool,
        outputStyle: String,
        codexContextWindow: Int = CodexContextWindow.modelDefault
    ) {
        self.init(
            model: session.model,
            effort: session.effort,
            agentKind: session.agentKind,
            permissionMode: session.permissionMode,
            isFastMode: isFastMode,
            outputStyle: outputStyle,
            codexContextWindow: codexContextWindow,
            // Read off the row rather than passed in, so the one caller that has a chat with no
            // worktree cannot forget to say so.
            hasWorktree: session.workspaceID != nil
        )
    }

    /// The modes this backend actually has.
    ///
    /// Codex has no Plan. Its permission story is an approval policy crossed with a sandbox, and
    /// there is nothing in that grid that means "work it out and do not touch anything". Offering
    /// the mode anyway would be a control that silently does nothing.
    ///
    /// Claude Code has no Approve for me, and loses nothing by it: its own Auto mode is that mode
    /// under another name, so a second row would be two names for one `--permission-mode auto`.
    /// See `PermissionMode.autoReview`.
    public var availablePermissionModes: [PermissionMode] {
        switch agentKind {
        case .codex: PermissionMode.allCases.filter { $0 != .plan }
        case .claudeCode, .cursor, .openCode: PermissionMode.allCases.filter { $0 != .autoReview }
        }
    }

    /// The rows the permission picker draws, each with the sentence that says what picking it
    /// would do. See `PermissionModeChoice`.
    public var permissionModeChoices: [PermissionModeChoice] {
        availablePermissionModes.map { PermissionModeChoice(mode: $0, on: agentKind) }
    }

    /// The one thing the permission picker has to say that no row of it can say, or nil where
    /// there is nothing.
    ///
    /// **It carried three facts and it is down to one**, which is the whole shape of this change.
    /// The first was the selected mode's own sentence, printed under the menu because an `NSMenu`
    /// row is one line with no space beneath it; every row carries its own sentence now, so the
    /// reader sees what a mode does before choosing it rather than after. The second named Plan
    /// as a mode Codex does not have, and the owner's answer to that was that the picker should
    /// do the right thing instead of explaining itself: Codex is not offered a Plan row and is
    /// not told about one either.
    ///
    /// What is left is the fact that is about this conversation rather than about any row in it.
    /// Every other chat in Bloom is in a worktree, which is a copy of a project cut for the
    /// purpose, so the widest mode there is full access to a copy. This one has no worktree, and
    /// the same words would mean the whole machine.
    public var permissionModeNote: String? {
        guard !hasWorktree else { return nil }
        return "This conversation has no worktree, so anything wider than "
            + "\(PermissionMode.auto.label(on: agentKind)) reaches the whole machine "
            + "rather than a copy of a project. Whatever you choose lasts until Bloom "
            + "next starts, and then it is back to that."
    }

    /// Whether this backend has output styles at all.
    ///
    /// Only Claude Code does. An output style is a Claude Code setting, delivered through that
    /// CLI's `outputStyle` key, and there is nothing in Codex it could be translated into. So the
    /// picker is not drawn for a Codex chat rather than drawn and ignored, which is the difference
    /// between a control that is absent and one that lies.
    ///
    /// Absent without explanation, which is the same answer the missing Plan row gets: a picker
    /// that quietly offers only what the running backend has is a picker that cannot lie, and a
    /// sentence about a control that is not there is a sentence nobody is looking for.
    public var offersOutputStyle: Bool {
        agentKind == .claudeCode
    }

    /// Whether this backend can be told how big its context window is.
    ///
    /// Only Codex, and for the same reason the output style is only Claude Code's: the two config
    /// keys behind it are Codex's own, and Claude Code's equivalent is not a setting at all but a
    /// model variant, `claude-opus-5[1m]`, which the model picker already offers. Drawing the row
    /// on a Claude Code chat would be a control that changes nothing. See `CodexContextWindow`.
    public var offersContextWindow: Bool {
        agentKind == .codex
    }

    /// What a session that does not exist yet should start out as, by the rules in
    /// `ComposerDefaults` plus the one thing those rules do not cover.
    public init(
        defaults: ComposerDefaults,
        isFastMode: Bool,
        outputStyle: String,
        codexContextWindow: Int = CodexContextWindow.modelDefault
    ) {
        self.init(
            model: defaults.model,
            effort: defaults.effort,
            // The backend comes with the model, so a Codex model set as the default opens a Codex
            // chat. It used to be left at `.claudeCode` here and in `AppModel.resolvedControls`,
            // which is what made the Models screen a Claude Code screen however it was set.
            agentKind: defaults.backend,
            permissionMode: defaults.permissionMode,
            isFastMode: isFastMode,
            outputStyle: outputStyle,
            codexContextWindow: codexContextWindow
        )
    }

    // MARK: - The three that are not columns

    /// Fast mode has no column on `Session`, so it lives in the store's key value table. Per
    /// session, and it survives a relaunch, which is all it promises.
    public static func fastModeKey(sessionID: SessionID) -> String {
        "session.\(sessionID).fastMode"
    }

    /// The output style has no column either, for the same reason and on the same terms.
    /// `AgentRunner.refreshOutputStyle` is what reads it back.
    public static func outputStyleKey(sessionID: SessionID) -> String {
        "session.\(sessionID).outputStyle"
    }

    /// The context window has no column either. `CodexRunner.refreshContextWindow` reads it back,
    /// and it is the one of the three that cannot simply be picked up on the next turn: it is a
    /// launch argument of a process that outlives every turn, so the runner reconnects when it
    /// changes. See `CodexContextWindow`.
    public static func contextWindowKey(sessionID: SessionID) -> String {
        "session.\(sessionID).codexContextWindow"
    }

    /// Records that a session has had its opening values settled, so `ComposerView.prepare` never
    /// re-applies the app-wide defaults over choices somebody has already made. It was written
    /// only by the composer's own first open; the create window writes it too, because a model
    /// picked in the sheet is exactly as deliberate as one picked in the footer and must survive
    /// the workspace being opened.
    public static func defaultsAppliedKey(sessionID: SessionID) -> String {
        "session.\(sessionID).defaultsApplied"
    }

    /// Writes the parts of these choices that a `Session` row cannot hold, and marks the session
    /// settled. The other four go on the row itself, wherever it is being written.
    ///
    /// All three store nil for their off state rather than a word for it, so a session that was
    /// never asked and one that was asked and said no read back the same. `AgentRunner` and
    /// `CodexRunner` treat them the same too, which is what keeps the two ends from disagreeing.
    public func store(sessionID: SessionID, in store: Store) async {
        try? await store.setSetting(
            Self.fastModeKey(sessionID: sessionID), isFastMode ? "1" : nil
        )
        try? await store.setSetting(
            Self.outputStyleKey(sessionID: sessionID),
            OutputStyle.isDefault(outputStyle) ? nil : outputStyle
        )
        try? await store.setSetting(
            Self.contextWindowKey(sessionID: sessionID),
            CodexContextWindow.stored(codexContextWindow)
        )
        try? await store.setSetting(Self.defaultsAppliedKey(sessionID: sessionID), "1")
    }
}
