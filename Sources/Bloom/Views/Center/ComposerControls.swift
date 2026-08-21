import Foundation
import BloomCore

/// Everything the composer's footer pickers choose about the next turn, as a value.
///
/// It exists because the footer now has two callers and only one of them has a `Session` to write
/// to. In a conversation these four live on the session row; in the create sheet the session has
/// not been made yet, and the same four have to be carried from the sheet into the row that gets
/// made. Naming them once means the footer is written against the choices rather than against
/// where they happen to be stored, and neither caller has to invent its own arrangement of
/// pickers.
///
/// Fast mode and the output style are in here with the columns even though neither has one on
/// `Session`. They are two of the things the footer offers, the user does not know or care which
/// of them SQLite holds, and leaving them out is what would make this a partial answer.
struct ComposerControls: Equatable, Sendable {
    var model: String
    var effort: String
    /// Which CLI runs the chat. Not a picker of its own: choosing a model out of the Codex section
    /// is choosing Codex, because a model already names its backend and a second menu saying the
    /// same thing would be a second thing to keep in step.
    var agentKind: AgentKind
    var permissionMode: PermissionMode
    var isFastMode: Bool
    /// How the agent is asked to write, by name. `OutputStyle.defaultName` for "leave it alone",
    /// which is what a session is until somebody picks something else.
    var outputStyle: String

    init(
        model: String = AppDefaults.fallbackModel,
        effort: String = AppDefaults.fallbackEffort,
        agentKind: AgentKind = .claudeCode,
        permissionMode: PermissionMode = AppDefaults.fallbackPermissionMode,
        isFastMode: Bool = false,
        outputStyle: String = OutputStyle.defaultName
    ) {
        self.model = model
        self.effort = effort
        self.agentKind = agentKind
        self.permissionMode = permissionMode
        self.isFastMode = isFastMode
        self.outputStyle = outputStyle
    }

    init(session: Session, isFastMode: Bool, outputStyle: String) {
        self.init(
            model: session.model,
            effort: session.effort,
            agentKind: session.agentKind,
            permissionMode: session.permissionMode,
            isFastMode: isFastMode,
            outputStyle: outputStyle
        )
    }

    /// The modes this backend actually has.
    ///
    /// Codex has no Plan. Its permission story is an approval policy crossed with a sandbox, and
    /// there is nothing in that grid that means "work it out and do not touch anything". Offering
    /// the mode anyway would be a control that silently does nothing.
    var availablePermissionModes: [PermissionMode] {
        switch agentKind {
        case .codex: PermissionMode.allCases.filter { $0 != .plan }
        case .claudeCode, .cursor, .openCode: PermissionMode.allCases
        }
    }

    /// What a menu says about the mode that is missing, so somebody who knows Bloom has a Plan
    /// mode is not left wondering where it went.
    var missingPermissionModeNote: String? {
        agentKind == .codex ? "Plan is a Claude Code mode. Codex has no equivalent." : nil
    }

    /// Whether this backend has output styles at all.
    ///
    /// Only Claude Code does. An output style is a Claude Code setting, delivered through that
    /// CLI's `outputStyle` key, and there is nothing in Codex it could be translated into. So the
    /// picker is not drawn for a Codex chat rather than drawn and ignored, which is the difference
    /// between a control that is absent and one that lies.
    ///
    /// Unlike Plan mode this gets no footnote, because there is no menu left to put one in: Plan
    /// is one row missing from a picker that still does its job, and this is the whole picker.
    var offersOutputStyle: Bool {
        agentKind == .claudeCode
    }

    /// What a session that does not exist yet should start out as, by the rules in
    /// `ComposerDefaults` plus the one thing those rules do not cover.
    init(defaults: ComposerDefaults, isFastMode: Bool, outputStyle: String) {
        self.init(
            model: defaults.model,
            effort: defaults.effort,
            permissionMode: defaults.permissionMode,
            isFastMode: isFastMode,
            outputStyle: outputStyle
        )
    }

    // MARK: - The two that are not columns

    /// Fast mode has no column on `Session`, so it lives in the store's key value table. Per
    /// session, and it survives a relaunch, which is all it promises.
    static func fastModeKey(sessionID: String) -> String {
        "session.\(sessionID).fastMode"
    }

    /// The output style has no column either, for the same reason and on the same terms.
    /// `AgentRunner.outputStyleKey` is the other half of this string.
    static func outputStyleKey(sessionID: String) -> String {
        "session.\(sessionID).outputStyle"
    }

    /// Records that a session has had its opening values settled, so `ComposerView.prepare` never
    /// re-applies the app-wide defaults over choices somebody has already made. It was written
    /// only by the composer's own first open; the create sheet writes it too, because a model
    /// picked in the sheet is exactly as deliberate as one picked in the footer and must survive
    /// the workspace being opened.
    static func defaultsAppliedKey(sessionID: String) -> String {
        "session.\(sessionID).defaultsApplied"
    }

    /// Writes the parts of these choices that a `Session` row cannot hold, and marks the session
    /// settled. The other three go on the row itself, wherever it is being written.
    ///
    /// Both of these store nil for their off state rather than a word for it, so a session that
    /// was never asked and one that was asked and said no read back the same. `AgentRunner` treats
    /// them the same too, which is what keeps the two ends from disagreeing.
    func store(sessionID: String, in store: Store) async {
        try? await store.setSetting(
            Self.fastModeKey(sessionID: sessionID), isFastMode ? "1" : nil
        )
        try? await store.setSetting(
            Self.outputStyleKey(sessionID: sessionID),
            OutputStyle.isDefault(outputStyle) ? nil : outputStyle
        )
        try? await store.setSetting(Self.defaultsAppliedKey(sessionID: sessionID), "1")
    }
}
