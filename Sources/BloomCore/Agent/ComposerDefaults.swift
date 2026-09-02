import Foundation

/// What a session that has never been opened starts out as.
///
/// Precedence, most specific first:
///
/// 1. **The session itself.** Handled by the caller: once a session has been prepared, or once it
///    has run an agent, nothing here touches it again. A choice the user made in the footer is
///    never overwritten.
/// 2. **The repository's settings file**, via `SettingsLoader.load(repo:)`. A repo that pins
///    `models.default` means it, and it means it more than a global preference does.
/// 3. **The app-level defaults** from Settings, Models (`AppDefaults`).
/// 4. **The built-in fallbacks**, which `AppDefaults` holds and `Session.init` matches.
///
/// The repository file has no say over permission mode, plan mode or fast mode, because it has no
/// keys for them, so those fall straight from level 3 to level 4.
///
/// **The backend is not a fifth value, it is a reading of the model.** Whichever layer above
/// supplied the model, that model names the CLI which runs it, and the effort and the permission
/// mode both follow it there. `DefaultBackend` is that reading, and it is why this returns a
/// backend rather than taking one and hoping the caller passed the right one.
public struct ComposerDefaults: Equatable {
    public var model: String
    public var effort: String
    public var permissionMode: PermissionMode
    /// Which CLI a chat opened on these values runs. Decided from the model rather than stated
    /// beside it, because a model id already names its backend: see `DefaultBackend` for the three
    /// questions and for why the one Settings recorded is asked first.
    public var backend: AgentKind = .claudeCode

    /// Pure, so the rules above can be checked without a store, a repository or a view.
    ///
    /// - Parameter hasWorktree: false for a conversation that is in no workspace, which is Ask
    ///   Bloom and nothing else today. It changes exactly one answer, and it is the one that
    ///   matters: the permission mode becomes `AskConversation.permissionMode` rather than the
    ///   owner's default.
    ///
    ///   **The default that overrules is not `acceptEdits`.**
    ///   `AppDefaults.fallbackPermissionMode` is `bypassPermissions`, and the Models tab can pin
    ///   anything over it, so a chat that inherited it would have opened on Full access: an agent
    ///   sitting above every project, running whatever it liked without asking. Neither of the two
    ///   modes that grant anything means what it usually means here anyway, because there is no
    ///   worktree for an accepted edit to be in.
    ///
    ///   The model and the effort are still the owner's, because those are about what a
    ///   conversation costs and that is the same question here as anywhere.
    /// - Parameter running: the backend the chat is already on, which is what an id nothing
    ///   recognises stays on. It is no longer what the answer runs on: the model decides that, and
    ///   the mode follows it. "Start in plan mode" is an app-wide switch, chosen before any model
    ///   is picked, and a Codex chat opened under it was being written a mode Codex cannot be
    ///   sent. `WorkspaceStart` runs its own answer through the same rule; this is the other route
    ///   a session's opening values arrive by.
    /// - Parameter codexModels: what `model/list` last answered, empty when it has not answered
    ///   yet, which is every caller that has never opened a model menu. It only ever adds
    ///   precision: the backend Settings recorded is read without it.
    public static func resolve(
        repo: RepoSettings,
        app: AppDefaults,
        hasWorktree: Bool = true,
        running: AgentKind = .claudeCode,
        codexModels: [CodexModel] = []
    ) -> ComposerDefaults {
        // Repo file, then what the user chose in Settings, then a machine-wide settings file, then
        // the built-in. The home file sits below the Settings screen deliberately: a global
        // Conductor file used to outrank every choice made in the UI, which made the Models screen
        // look broken on a machine that had one.
        let model = firstNonEmpty(
            repo.defaultModel,
            app.storedModel,
            repo.homeDefaultModel,
            fallback: app.model
        )
        // The backend and the effort come out of the same call, because on Codex the second is a
        // property of the first: a level the chosen model does not take is a level the server
        // refuses. See `DefaultBackend`.
        let resolved = DefaultBackend.resolve(
            model: model,
            effort: firstNonEmpty(
                repo.defaultEffort,
                app.storedEffort,
                repo.homeDefaultEffort,
                fallback: app.effort
            ),
            app: app,
            running: running,
            codexModels: codexModels
        )
        return ComposerDefaults(
            model: model,
            effort: resolved.effort,
            // "Start in plan mode" is the more specific instruction of the two, so it beats the
            // permission mode picker when both are set rather than the two fighting over one column.
            //
            // Through the backend the model just landed on rather than through the caller's, which
            // is the whole point of settling the two together: Plan plus a Codex default used to
            // depend on the caller passing the right backend in, and the create window passed none.
            permissionMode: (hasWorktree
                ? (app.planMode ? .plan : app.permissionMode)
                : AskConversation.permissionMode).nearest(on: resolved.kind),
            backend: resolved.kind
        )
    }

    /// The first candidate that is actually set, in precedence order. An empty string counts as
    /// unset, because a settings file with `default = ""` means "I did not choose", not "choose
    /// nothing".
    public static func firstNonEmpty(_ candidates: String?..., fallback: String) -> String {
        for candidate in candidates {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                return candidate
            }
        }
        return fallback
    }
}
