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
    case mergeInstructions = "instructions.merge"
    case conflictInstructions = "instructions.fix_conflicts"

    /// The key path as components, for the document editor.
    public var path: [String] { rawValue.components(separatedBy: ".") }
}

/// Which script a `ScriptFile` belongs to. Run scripts are named by their table under
/// `scripts.run`, which is the same id a `RunScript` carries.
public enum ScriptLocation: Sendable, Hashable {
    case setup
    case archive
    case run(String)
}

/// A script that lives in a file of its own rather than inside a TOML string.
///
/// A setup script is a program: it has a shebang, it wants `shellcheck`, and it wants to be run
/// straight from a terminal while it is being written. None of that is true of a string inside a
/// settings file, where the container's own escaping rules start applying to the user's shell
/// quoting. So `scripts.setup_file` names a real executable file and `scripts.setup` is what is
/// still read from settings written before that, and from Conductor's.
public struct ScriptFile: Sendable, Hashable {
    /// As the settings file states it, which is relative to the repository unless it is absolute.
    public var path: String
    /// The settings file names this path and nothing is there. The script does not run, and the
    /// window says so rather than showing an empty box.
    public var isMissing: Bool

    public init(path: String, isMissing: Bool) {
        self.path = path
        self.isMissing = isMissing
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
    /// What this project adds to the turn Bloom sends when someone presses Merge, and the one it
    /// sends for Fix merge conflicts. Bloom's own words are not here and never were: for merging
    /// they are in the message it composes, and for conflicts they are the file
    /// `ConflictInstructions` writes. These are the project's, they go after Bloom's, they win
    /// where the two disagree, and they are attached only when there are any. See
    /// `ProjectInstructions`, which also says why the same words written into
    /// `.bloom/merge-instructions.md` beat these.
    public var mergeInstructions: String?
    public var conflictInstructions: String?
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
    /// For each script whose settings file named a file rather than embedding the text, that
    /// file. Absent means the script is a string inside the settings file, or there is none.
    public var scriptFiles: [ScriptLocation: ScriptFile] = [:]
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
            apply(toml, from: path, to: &settings, repo: repo)
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
            apply(toml, from: path, to: &settings, repo: repo)
        }

        return settings
    }

    /// The absolute path a settings file's script reference points at.
    ///
    /// Relative to the repository rather than to the settings file, so `.bloom/setup.sh` reads
    /// the same whichever of the four files names it, and so a path stays meaningful when a value
    /// is promoted from `.conductor` to `.bloom`.
    public static func resolve(_ path: String, repo: String) -> String {
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
        return (repo as NSString).appendingPathComponent(path)
    }

    /// One script a settings file states, either as a path or as an embedded string.
    ///
    /// The path wins inside a single file. Across files nothing special happens: the ordinary
    /// layering already means the last file to state a script replaces what the ones below it
    /// said, in whichever of the two forms each of them used.
    private static func readScript(
        _ toml: TOMLValue, inline: String, file: String, repo: String
    ) -> (text: String?, file: ScriptFile?)? {
        if let stated = toml[file]?.stringValue, !stated.isEmpty {
            let full = resolve(stated, repo: repo)
            guard let text = try? String(contentsOfFile: full, encoding: .utf8) else {
                return (nil, ScriptFile(path: stated, isMissing: true))
            }
            let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return (hasContent ? text : nil, ScriptFile(path: stated, isMissing: false))
        }
        guard let text = toml[inline]?.stringValue else { return nil }
        return (text.isEmpty ? nil : text, nil)
    }

    static func apply(
        _ toml: TOMLValue, from source: String, to settings: inout RepoSettings, repo: String = ""
    ) {
        /// Records which file had the last word about a key, so an edit can be written back to it.
        func note(_ key: SettingsKey) { settings.origins[key] = source }

        // An empty string is a statement, not an absent value: it is the only way a file can say
        // "this repository has no setup script" loudly enough to beat one that a file below it
        // states. That matters now that Bloom writes to `.bloom` and never to `.conductor`, so
        // clearing a script a Conductor file states cannot be done by deleting a line, only by
        // overriding it from higher up.
        if let setup = readScript(toml, inline: "scripts.setup", file: "scripts.setup_file", repo: repo) {
            settings.setupScript = setup.text
            settings.scriptFiles[.setup] = setup.file
            note(.setupScript)
        }
        if let archive = readScript(toml, inline: "scripts.archive", file: "scripts.archive_file", repo: repo) {
            settings.archiveScript = archive.text
            settings.scriptFiles[.archive] = archive.file
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
                var files: [ScriptLocation: ScriptFile] = [:]
                let scripts = named
                    .sorted { $0.key < $1.key }
                    .compactMap { key, value -> RunScript? in
                        let name = value["name"]?.stringValue ?? key.capitalizedFirst
                        // A run script is usually one command and stays a string. It gets a file
                        // of its own on the same terms as the setup script: when it is long
                        // enough to be a program. See `SettingsWriter.wantsAFile`.
                        if let stated = value["file"]?.stringValue, !stated.isEmpty {
                            let full = resolve(stated, repo: repo)
                            let text = try? String(contentsOfFile: full, encoding: .utf8)
                            files[.run(key)] = ScriptFile(path: stated, isMissing: text == nil)
                            return RunScript(id: key, name: name, command: text ?? "")
                        }
                        let command = value["command"]?.stringValue ?? value.stringValue
                        guard let command, !command.isEmpty else { return nil }
                        return RunScript(id: key, name: name, command: command)
                    }
                if !scripts.isEmpty {
                    settings.runScripts = scripts
                    for (location, file) in files { settings.scriptFiles[location] = file }
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
        // An empty string is a statement here for the same reason it is one for a script: it is
        // the only way a file can say "this project has nothing extra to say about merging"
        // loudly enough to beat a file below it that does.
        if let text = toml["instructions.merge"]?.stringValue {
            settings.mergeInstructions = text.isEmpty ? nil : text
            note(.mergeInstructions)
        }
        if let text = toml["instructions.fix_conflicts"]?.stringValue {
            settings.conflictInstructions = text.isEmpty ? nil : text
            note(.conflictInstructions)
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
        public static let outputStyle = "defaults.outputStyle"
    }

    /// The built-in fallbacks, which `Session`'s own initialiser now reads rather than restates.
    /// Nothing else may invent a second set of hard-coded defaults.
    public static let fallbackModel = "opus"
    public static let fallbackEffort = "high"
    /// Full access, because that is what the owner asked a new session to start on: a session
    /// that stops to ask before its first command is a session somebody has to sit and watch,
    /// and Bloom exists to run several at once.
    ///
    /// This is a fallback, not an override. The moment `defaults.permissionMode` holds anything
    /// at all, the Settings, Models picker wins, which is why a copy of Bloom whose Models tab
    /// has ever been saved keeps whatever that tab last wrote. See `AppDefaults.load`.
    public static let fallbackPermissionMode = PermissionMode.bypassPermissions

    public var model: String
    public var effort: String
    public var reviewModel: String
    public var reviewEffort: String
    public var permissionMode: PermissionMode
    public var planMode: Bool
    public var fastMode: Bool
    /// Which output style a new session opens on, by name, or `OutputStyle.defaultName` for none.
    ///
    /// A name rather than a case, because the set is open: the four the CLI compiles in are only
    /// the ones it ships with, and anybody can add another by writing a file in
    /// `~/.claude/output-styles`. See `OutputStyleIndex`.
    public var outputStyle: String

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
        fastMode: Bool = false,
        outputStyle: String = OutputStyle.defaultName
    ) {
        self.model = model
        self.effort = effort
        self.reviewModel = reviewModel
        self.reviewEffort = reviewEffort
        self.permissionMode = permissionMode
        self.planMode = planMode
        self.fastMode = fastMode
        self.outputStyle = outputStyle
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
        defaults.outputStyle = await value(Key.outputStyle) ?? OutputStyle.defaultName
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
        // Nil rather than the word, so "never chosen" and "chosen and then cleared" cannot drift
        // apart. Every other reader of this value asks `OutputStyle.isDefault` rather than
        // comparing strings, and this is what keeps that question cheap to answer.
        try? await store.setSetting(
            Key.outputStyle, OutputStyle.isDefault(outputStyle) ? nil : outputStyle
        )
    }
}
