import BloomCore

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
struct ComposerDefaults: Equatable {
    var model: String
    var effort: String
    var permissionMode: PermissionMode

    /// Pure, so the rules above can be checked without a store, a repository or a view.
    static func resolve(repo: RepoSettings, app: AppDefaults) -> ComposerDefaults {
        // Repo file, then what the user chose in Settings, then a machine-wide settings file, then
        // the built-in. The home file sits below the Settings screen deliberately: a global
        // Conductor file used to outrank every choice made in the UI, which made the Models screen
        // look broken on a machine that had one.
        ComposerDefaults(
            model: firstNonEmpty(
                repo.defaultModel,
                app.storedModel,
                repo.homeDefaultModel,
                fallback: app.model
            ),
            effort: firstNonEmpty(
                repo.defaultEffort,
                app.storedEffort,
                repo.homeDefaultEffort,
                fallback: app.effort
            ),
            // "Start in plan mode" is the more specific instruction of the two, so it beats the
            // permission mode picker when both are set rather than the two fighting over one column.
            permissionMode: app.planMode ? .plan : app.permissionMode
        )
    }

    /// The first candidate that is actually set, in precedence order. An empty string counts as
    /// unset, because a settings file with `default = ""` means "I did not choose", not "choose
    /// nothing".
    static func firstNonEmpty(_ candidates: String?..., fallback: String) -> String {
        for candidate in candidates {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                return candidate
            }
        }
        return fallback
    }
}
