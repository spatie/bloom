import Foundation

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
    public var defaultModel: String?
    public var defaultEffort: String?
    /// Paths of the settings files that contributed, newest last. Shown in the settings UI.
    public var sources: [String] = []

    public init() {}

    public var primaryRunScript: RunScript? { runScripts.first }
}

public enum SettingsLoader {
    /// Lowest precedence first.
    public static func candidatePaths(repo: String) -> [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.conductor/settings.toml",
            "\(home)/.baton/settings.toml",
            "\(repo)/.conductor/settings.toml",
            "\(repo)/.baton/settings.toml",
            "\(repo)/.conductor/settings.local.toml",
            "\(repo)/.baton/settings.local.toml",
        ]
    }

    public static func load(repo: String) -> RepoSettings {
        var settings = RepoSettings()

        for path in candidatePaths(repo: repo) {
            guard let toml = try? TOML.parse(contentsOf: path) else { continue }
            settings.sources.append(path)
            apply(toml, to: &settings)
        }

        return settings
    }

    static func apply(_ toml: TOMLValue, to settings: inout RepoSettings) {
        if let setup = toml["scripts.setup"]?.stringValue, !setup.isEmpty {
            settings.setupScript = setup
        }
        if let archive = toml["scripts.archive"]?.stringValue, !archive.isEmpty {
            settings.archiveScript = archive
        }
        if let mode = toml["scripts.run_mode"]?.stringValue {
            settings.runMode = mode
        }
        if let mode = toml["runScriptMode"]?.stringValue {
            settings.runMode = mode
        }

        if let run = toml["scripts.run"] {
            switch run {
            case .string(let command) where !command.isEmpty:
                settings.runScripts = [RunScript(id: "run", name: "Run", command: command)]
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
                if !scripts.isEmpty { settings.runScripts = scripts }
            default:
                break
            }
        }

        for key in ["files_to_copy", "filesToCopy", "files.copy"] {
            if let files = toml[key]?.stringArray, !files.isEmpty {
                settings.filesToCopy = files
            }
        }

        if let prefix = toml["git.branch_prefix"]?.stringValue {
            settings.branchPrefix = prefix
        }
        if let type = toml["git.branch_prefix_type"]?.stringValue {
            switch type {
            case "github_username":
                settings.branchPrefix = GitHubIdentity.cachedUsername
            case "none":
                settings.branchPrefix = nil
            default:
                break
            }
        }
        if let delete = toml["git.delete_branch_on_archive"]?.boolValue {
            settings.deleteBranchOnArchive = delete
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
public enum GitHubIdentity {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: String?
    nonisolated(unsafe) private static var resolved = false

    public static var cachedUsername: String? {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    public static func resolve() async {
        guard !isResolved() else { return }

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

        store(username)
    }

    private static func isResolved() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return resolved
    }

    private static func store(_ username: String?) {
        lock.lock(); defer { lock.unlock() }
        cached = username
        resolved = true
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
        defaults.model = await value(Key.model) ?? fallbackModel
        defaults.effort = await value(Key.effort) ?? fallbackEffort
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
