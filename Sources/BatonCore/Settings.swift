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

extension String {
    var capitalizedFirst: String {
        isEmpty ? self : prefix(1).uppercased() + dropFirst()
    }
}
