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
/// Fast mode is in here with the other three even though it has no column on `Session`. It is one
/// of the four things the footer offers, the user does not know or care which of them SQLite holds,
/// and leaving it out is what would make this a partial answer.
struct ComposerControls: Equatable, Sendable {
    var model: String
    var effort: String
    var permissionMode: PermissionMode
    var isFastMode: Bool

    init(
        model: String = AppDefaults.fallbackModel,
        effort: String = AppDefaults.fallbackEffort,
        permissionMode: PermissionMode = AppDefaults.fallbackPermissionMode,
        isFastMode: Bool = false
    ) {
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.isFastMode = isFastMode
    }

    init(session: Session, isFastMode: Bool) {
        self.init(
            model: session.model,
            effort: session.effort,
            permissionMode: session.permissionMode,
            isFastMode: isFastMode
        )
    }

    /// What a session that does not exist yet should start out as, by the rules in
    /// `ComposerDefaults` plus the one thing those rules do not cover.
    init(defaults: ComposerDefaults, isFastMode: Bool) {
        self.init(
            model: defaults.model,
            effort: defaults.effort,
            permissionMode: defaults.permissionMode,
            isFastMode: isFastMode
        )
    }

    // MARK: - The two that are not columns

    /// Fast mode has no column on `Session`, so it lives in the store's key value table. Per
    /// session, and it survives a relaunch, which is all it promises.
    static func fastModeKey(sessionID: String) -> String {
        "session.\(sessionID).fastMode"
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
    func store(sessionID: String, in store: Store) async {
        try? await store.setSetting(
            Self.fastModeKey(sessionID: sessionID), isFastMode ? "1" : nil
        )
        try? await store.setSetting(Self.defaultsAppliedKey(sessionID: sessionID), "1")
    }
}
