import Foundation
import Synchronization

public struct RunScript: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var command: String

    public init(id: String, name: String, command: String) {
        self.id = id
        self.name = name
        self.command = command
    }
}

/// One editable setting, named so that "where did this value come from" and "where should an
/// edit to it go" can both be answered by looking it up rather than by matching strings.
///
/// The raw value is the TOML key path the writer uses. `runScripts` is the exception: the run
/// scripts are a table of tables, so the writer addresses each script under `scripts.run` by id
/// rather than writing this path directly.
public enum SettingsKey: String, Sendable, Hashable, CaseIterable {
    case setupScript = "scripts.setup"
    case archiveScript = "scripts.archive"
    case runScripts = "scripts.run"
    case runMode = "scripts.run_mode"
    case filesToCopy = "file_include_globs"
    case branchPrefix = "git.branch_prefix"
    case deleteBranchOnArchive = "git.delete_branch_on_archive"

    /// The key path as components, for the document editor.
    public var path: [String] { rawValue.components(separatedBy: ".") }
}

/// The effective configuration for one repository, after layering every settings file that
/// applies. Conductor's own files are read as-is so an existing repo needs no new config.
public struct RepoSettings: Sendable, Hashable {
    public var setupScript: String?
    public var archiveScript: String?
    public var runScripts: [RunScript] = []
    public var runMode: String = "nonconcurrent"
    public var filesToCopy: [String] = [".env*"]
    public var branchPrefix: String?
    public var deleteBranchOnArchive: Bool = false
    /// Set by a file inside the repository. Ranks ABOVE the app-level defaults, because pinning
    /// a model in a project's own settings is a deliberate statement about that project.
    public var defaultModel: String?
    public var defaultEffort: String?
    /// Set by a machine-wide file (`~/.conductor/settings.toml`, `~/.bloom/settings.toml`).
    ///
    /// Kept apart from the repo-scoped values because it ranks BELOW the Models screen. Both are
    /// "what this user generally wants", and when they disagree the one the user just used in the
    /// UI should win over a file they wrote once and forgot. Merging the two layers meant a global
    /// Conductor file silently overrode every choice made in Settings.
    public var homeDefaultModel: String?
    public var homeDefaultEffort: String?
    /// Paths of the settings files that contributed, newest last. Shown in the settings UI.
    public var sources: [String] = []

    /// For each setting that some file actually stated, the path of the file that stated it last
    /// and therefore won. Absent means "nothing on this machine sets it, the default is showing".
    ///
    /// This is what makes the settings screen editable rather than merely informative: an edit is
    /// written back to the file the value came from, so the user changes the same line they would
    /// have changed by hand, and a teammate's committed `.conductor/settings.toml` is never
    /// shadowed by an invisible copy somewhere else. See `SettingsWriter.destination`.
    public var origins: [SettingsKey: String] = [:]

    public init() {}
}

public enum SettingsLoader {
    /// Machine-wide files, lowest precedence first.
    ///
    /// `.conductor` is read on purpose rather than as a leftover: a repository that already has
    /// one is a repository this app can pick up with nothing to configure.
    public static func homePaths() -> [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.conductor/settings.toml",
            "\(home)/.bloom/settings.toml",
        ]
    }

    /// Files inside the repository, lowest precedence first.
    public static func repoPaths(repo: String) -> [String] {
        [
            "\(repo)/.conductor/settings.toml",
            "\(repo)/.bloom/settings.toml",
            "\(repo)/.conductor/settings.local.toml",
            "\(repo)/.bloom/settings.local.toml",
        ]
    }

    /// Lowest precedence first.
    public static func candidatePaths(repo: String) -> [String] {
        homePaths() + repoPaths(repo: repo)
    }

    public static func load(repo: String) -> RepoSettings {
        var settings = RepoSettings()

        for path in homePaths() {
            guard let toml = try? TOML.parse(contentsOf: path) else { continue }
            settings.sources.append(path)
            apply(toml, from: path, to: &settings)
        }

        // Everything a home file said about the model belongs to the home layer. Moving it aside
        // before the repo files are read is what keeps the two layers from collapsing into one.
        settings.homeDefaultModel = settings.defaultModel
        settings.homeDefaultEffort = settings.defaultEffort
        settings.defaultModel = nil
        settings.defaultEffort = nil

        for path in repoPaths(repo: repo) {
            guard let toml = try? TOML.parse(contentsOf: path) else { continue }
            settings.sources.append(path)
            apply(toml, from: path, to: &settings)
        }

        return settings
    }

    static func apply(_ toml: TOMLValue, from source: String, to settings: inout RepoSettings) {
        /// Records which file had the last word about a key, so an edit can be written back to it.
        func note(_ key: SettingsKey) { settings.origins[key] = source }

        // An empty string is a statement, not an absent value: it is the only way a file can say
        // "this repository has no setup script" loudly enough to beat one that a file below it
        // states. That matters now that Bloom writes to `.bloom` and never to `.conductor`, so
        // clearing a script a Conductor file states cannot be done by deleting a line, only by
        // overriding it from higher up.
        if let setup = toml["scripts.setup"]?.stringValue {
            settings.setupScript = setup.isEmpty ? nil : setup
            note(.setupScript)
        }
        if let archive = toml["scripts.archive"]?.stringValue {
            settings.archiveScript = archive.isEmpty ? nil : archive
            note(.archiveScript)
        }
        if let mode = toml["scripts.run_mode"]?.stringValue {
            settings.runMode = mode
            note(.runMode)
        }
        if let mode = toml["runScriptMode"]?.stringValue {
            settings.runMode = mode
            note(.runMode)
        }

        if let run = toml["scripts.run"] {
            switch run {
            case .string(let command) where !command.isEmpty:
                settings.runScripts = [RunScript(id: "run", name: "Run", command: command)]
                note(.runScripts)
            case .table(let named):
                let scripts = named
                    .sorted { $0.key < $1.key }
                    .compactMap { key, value -> RunScript? in
                        let command = value["command"]?.stringValue ?? value.stringValue
                        guard let command, !command.isEmpty else { return nil }
                        return RunScript(
                            id: key,
                            name: value["name"]?.stringValue ?? key.capitalizedFirst,
                            command: command
                        )
                    }
                if !scripts.isEmpty {
                    settings.runScripts = scripts
                    note(.runScripts)
                }
            default:
                break
            }
        }

        // `file_include_globs` is what Conductor's own repository schema calls this, and it was
        // missing here: a repository configured in Conductor copied nothing in Bloom, silently,
        // because the three spellings read were all ones nothing writes. It goes first so the
        // others still win when a file happens to carry both.
        //
        // An empty list is honoured rather than ignored. It used to be treated as "said nothing",
        // which left "copy nothing into a new workspace" impossible to express: clearing the field
        // put `.env*` back. A key that is present means the file has an opinion, including the
        // opinion that the answer is none.
        for key in ["file_include_globs", "files_to_copy", "filesToCopy", "files.copy"] {
            if let files = toml[key]?.stringArray {
                settings.filesToCopy = files
                settings.origins[.filesToCopy] = source
            }
        }

        if let prefix = toml["git.branch_prefix"]?.stringValue {
            settings.branchPrefix = prefix
            note(.branchPrefix)
        }
        if let type = toml["git.branch_prefix_type"]?.stringValue {
            switch type {
            case "github_username":
                settings.branchPrefix = GitHubIdentity.cachedUsername
                note(.branchPrefix)
            case "none":
                settings.branchPrefix = nil
                note(.branchPrefix)
            default:
                break
            }
        }
        if let delete = toml["git.delete_branch_on_archive"]?.boolValue {
            settings.deleteBranchOnArchive = delete
            note(.deleteBranchOnArchive)
        }
        if let model = toml["models.default"]?.stringValue {
            settings.defaultModel = model
        }
        if let effort = toml["models.claude.default_thinking_level"]?.stringValue {
            settings.defaultEffort = effort
        }
    }
}

/// The GitHub login, used for branch prefixes. Resolved once per launch because `gh` is slow.
///
/// A `Mutex` rather than a lock beside two `nonisolated(unsafe)` variables: the state can then
/// only be reached through the lock, so "forgot to take it here" stops being possible to write.
public enum GitHubIdentity {
    private struct Identity {
        var username: String?
        var resolved = false
    }

    private static let state = Mutex(Identity())

    public static var cachedUsername: String? {
        state.withLock(\.username)
    }

    public static func resolve() async {
        guard !state.withLock(\.resolved) else { return }

        var username: String?
        if let result = try? await Shell.run("gh", ["api", "user", "--jq", ".login"], timeout: .seconds(10)),
           result.ok, !result.trimmed.isEmpty {
            username = result.trimmed
        }
        if username == nil,
           let result = try? await Shell.run("git", ["config", "--get", "github.user"]),
           result.ok, !result.trimmed.isEmpty {
            username = result.trimmed
        }

        state.withLock {
            $0.username = username
            $0.resolved = true
        }
    }
}

public extension String {
    var capitalizedFirst: String {
        isEmpty ? self : prefix(1).uppercased() + dropFirst()
    }
}

/// The application-wide defaults a brand new session inherits, edited in Settings, Models.
///
/// These live in the store's key value table rather than in a settings file, because they are the
/// user's own preference across every repository, and a repository's own file is allowed to
/// override them (see `resolve` on the composer side for the full precedence).
public struct AppDefaults: Sendable, Hashable {
    /// Store keys. Kept next to the type so a rename cannot leave a stale string behind in a view.
    public enum Key {
        public static let model = "defaults.model"
        public static let effort = "defaults.effort"
        public static let reviewModel = "defaults.review.model"
        public static let reviewEffort = "defaults.review.effort"
        public static let permissionMode = "defaults.permissionMode"
        public static let planMode = "defaults.planMode"
        public static let fastMode = "defaults.fastMode"
    }

    /// The built-in fallbacks, which match `Session`'s own initialiser. Nothing else may invent a
    /// second set of hard-coded defaults.
    public static let fallbackModel = "opus"
    public static let fallbackEffort = "high"
    public static let fallbackPermissionMode = PermissionMode.acceptEdits

    public var model: String
    public var effort: String
    public var reviewModel: String
    public var reviewEffort: String
    public var permissionMode: PermissionMode
    public var planMode: Bool
    public var fastMode: Bool

    /// Nil when the user has never chosen one in Settings. `model` always holds a usable value,
    /// so it cannot answer "did they pick this, or is it just the fallback?", and that question is
    /// what decides whether a machine-wide settings file gets a say.
    public var storedModel: String?
    public var storedEffort: String?

    public init(
        model: String = AppDefaults.fallbackModel,
        effort: String = AppDefaults.fallbackEffort,
        reviewModel: String = AppDefaults.fallbackModel,
        reviewEffort: String = AppDefaults.fallbackEffort,
        permissionMode: PermissionMode = AppDefaults.fallbackPermissionMode,
        planMode: Bool = false,
        fastMode: Bool = false
    ) {
        self.model = model
        self.effort = effort
        self.reviewModel = reviewModel
        self.reviewEffort = reviewEffort
        self.permissionMode = permissionMode
        self.planMode = planMode
        self.fastMode = fastMode
    }

    /// A missing row means "never chosen", so every read falls back rather than failing.
    public static func load(from store: Store) async -> AppDefaults {
        func value(_ key: String) async -> String? {
            let raw = try? await store.setting(key)
            guard let raw, !raw.isEmpty else { return nil }
            return raw
        }

        var defaults = AppDefaults()
        defaults.storedModel = await value(Key.model)
        defaults.storedEffort = await value(Key.effort)
        defaults.model = defaults.storedModel ?? fallbackModel
        defaults.effort = defaults.storedEffort ?? fallbackEffort
        defaults.reviewModel = await value(Key.reviewModel) ?? defaults.model
        defaults.reviewEffort = await value(Key.reviewEffort) ?? defaults.effort
        if let raw = await value(Key.permissionMode), let mode = PermissionMode(rawValue: raw) {
            defaults.permissionMode = mode
        }
        defaults.planMode = await value(Key.planMode) == "1"
        defaults.fastMode = await value(Key.fastMode) == "1"
        return defaults
    }

    public func save(to store: Store) async {
        try? await store.setSetting(Key.model, model)
        try? await store.setSetting(Key.effort, effort)
        try? await store.setSetting(Key.reviewModel, reviewModel)
        try? await store.setSetting(Key.reviewEffort, reviewEffort)
        try? await store.setSetting(Key.permissionMode, permissionMode.rawValue)
        try? await store.setSetting(Key.planMode, planMode ? "1" : "0")
        try? await store.setSetting(Key.fastMode, fastMode ? "1" : "0")
    }
}
