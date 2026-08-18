import Foundation

/// One setting the user changed, with its new value. `nil` means "stop stating this here", which
/// removes the key rather than writing an empty one, so a file only ever says what it means.
public enum SettingsEdit: Sendable, Hashable {
    case setupScript(String?)
    case archiveScript(String?)
    case runScripts([RunScript])
    case runMode(String)
    case filesToCopy([String])
    case branchPrefix(String?)
    case deleteBranchOnArchive(Bool)

    var key: SettingsKey {
        switch self {
        case .setupScript: .setupScript
        case .archiveScript: .archiveScript
        case .runScripts: .runScripts
        case .runMode: .runMode
        case .filesToCopy: .filesToCopy
        case .branchPrefix: .branchPrefix
        case .deleteBranchOnArchive: .deleteBranchOnArchive
        }
    }
}

/// Writes repository settings back to the files they came from.
///
/// # Why there is no second source of truth
///
/// The settings a repository has are already stated in files: `<repo>/.conductor/settings.toml`
/// and its `.local` sibling, which is where Conductor puts them and where a team commits the ones
/// they share. Bloom reads those files. The obvious way to make the screen editable is to keep
/// overrides in Bloom's own database and layer them on top, and that was rejected:
///
/// * The value would then exist twice, and the copy that wins would be the invisible one. A
///   teammate who fixes `scripts.setup` in the committed file, and a user whose app is quietly
///   overriding it, would disagree forever with nothing on screen to explain why.
/// * The scripts have to run for `git` worktrees created by other tools and by Conductor itself.
///   A value only Bloom's database knows is a value nothing else can honour.
/// * "Edit it in the app, then look at the file" has to show the change. That is only true if the
///   app edits the file.
///
/// So the app edits the files, and the only question left is which one. The answer is: **the file
/// that already states this setting**. Change the setup script and the line that changes is the
/// line you would have changed by hand, in the same file, ready to be committed or reverted with
/// `git`. Nothing is shadowed and nothing is clobbered, because a key that lives in a teammate's
/// committed file is edited there deliberately and visibly, rather than overridden from a place
/// no diff will ever show.
///
/// A setting that no repository file states yet goes to `defaultFile`, and the screen names that
/// path next to the field before anything is written, so the destination is never a surprise.
public enum SettingsWriter {
    /// The file an edit to `key` will be written to.
    ///
    /// The file that already states it, when that file belongs to the repository. A value that
    /// only a machine-wide file states is deliberately NOT edited in place: this screen is about
    /// one repository, and silently rewriting `~/.conductor/settings.toml` from it would change
    /// every other repository on the machine.
    public static func destination(for key: SettingsKey, in settings: RepoSettings, repo: String) -> String {
        if let origin = settings.origins[key], SettingsLoader.repoPaths(repo: repo).contains(origin) {
            return origin
        }
        return defaultFile(repo: repo)
    }

    /// Where a setting goes when no repository file states it yet.
    ///
    /// The shared, committable file rather than the `.local` one: a setup script or a list of
    /// files to copy is nearly always something the whole team needs, and a value that should stay
    /// on one machine can be moved to `settings.local.toml` by hand afterwards. `.conductor` is
    /// preferred over `.bloom` because Conductor reads it too, so one file serves both apps rather
    /// than splitting a repository's configuration in half.
    public static func defaultFile(repo: String) -> String {
        let manager = FileManager.default
        let conductor = (repo as NSString).appendingPathComponent(".conductor/settings.toml")
        let bloom = (repo as NSString).appendingPathComponent(".bloom/settings.toml")

        if manager.fileExists(atPath: conductor) { return conductor }
        if manager.fileExists(atPath: bloom) { return bloom }
        if manager.fileExists(atPath: (repo as NSString).appendingPathComponent(".conductor")) {
            return conductor
        }
        if manager.fileExists(atPath: (repo as NSString).appendingPathComponent(".bloom")) {
            return bloom
        }
        return conductor
    }

    /// Applies every edit, touching each destination file once.
    ///
    /// Returns the paths that were written, so the caller can say what changed. Reading each file
    /// immediately before rewriting it is what keeps a change made on disk in the meantime: only
    /// the keys named here are replaced, everything else in the file is carried through untouched.
    @discardableResult
    public static func write(
        _ edits: [SettingsEdit],
        repo: String,
        settings: RepoSettings
    ) throws -> [String] {
        var byFile: [String: [SettingsEdit]] = [:]
        for edit in edits {
            byFile[destination(for: edit.key, in: settings, repo: repo), default: []].append(edit)
        }

        var written: [String] = []
        for (path, fileEdits) in byFile.sorted(by: { $0.key < $1.key }) {
            var document = SettingsDocument(contentsOf: path)
            let before = document.text
            for edit in fileEdits { apply(edit, to: &document) }
            guard document.text != before else { continue }
            // A file that did not exist and would still say nothing is not worth creating.
            if !document.exists, document.isEmpty { continue }
            try document.write(to: path)
            written.append(path)
        }
        return written
    }

    static func apply(_ edit: SettingsEdit, to document: inout SettingsDocument) {
        switch edit {
        case .setupScript(let script):
            set(script, at: SettingsKey.setupScript.path, in: &document)
        case .archiveScript(let script):
            set(script, at: SettingsKey.archiveScript.path, in: &document)
        case .runMode(let mode):
            document.set(.string(mode), at: SettingsKey.runMode.path)
        case .branchPrefix(let prefix):
            set(prefix, at: SettingsKey.branchPrefix.path, in: &document)
        case .deleteBranchOnArchive(let flag):
            document.set(.boolean(flag), at: SettingsKey.deleteBranchOnArchive.path)
        case .filesToCopy(let globs):
            // Written under Conductor's own key even when the file currently spells it one of the
            // three other ways the loader accepts, because that is the spelling both apps and the
            // published schema agree on. The old key is removed in the same pass so the file does
            // not end up stating the same list twice.
            for legacy in ["files_to_copy", "filesToCopy"] {
                document.remove(at: [legacy])
            }
            document.remove(at: ["files", "copy"])
            document.set(.strings(globs), at: SettingsKey.filesToCopy.path)
        case .runScripts(let scripts):
            writeRunScripts(scripts, to: &document)
        }
    }

    private static func set(_ value: String?, at path: [String], in document: inout SettingsDocument) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            document.set(.string(trimmed), at: path)
        } else {
            document.remove(at: path)
        }
    }

    /// Rewrites `[scripts.run.*]` to exactly the scripts given.
    ///
    /// The legacy single-string `scripts.run` goes at the same time. Leaving it would be worse
    /// than useless: the loader reads a string OR a table, so a file holding both would keep
    /// answering with whichever the parser folded them into rather than with what the user just
    /// typed.
    private static func writeRunScripts(_ scripts: [RunScript], to document: inout SettingsDocument) {
        // Safe to do unconditionally: `remove` only ever matches a `key = value` line, never a
        // `[scripts.run.dev]` header, so this takes the legacy string and nothing else.
        document.remove(at: SettingsKey.runScripts.path)

        let wanted = Set(scripts.map(\.id))
        for table in document.tables(under: ["scripts", "run"]) {
            guard let id = table.last, !wanted.contains(id) else { continue }
            document.removeTable(at: table)
        }

        for script in scripts {
            let base = SettingsKey.runScripts.path + [script.id]
            document.set(.string(script.command), at: base + ["command"])
            // Only when it says something the id does not. `name` is Bloom's own key, and writing
            // "Dev" beside an id of `dev` on every save would add a line to the team's file that
            // carries no information.
            if script.name == script.id.capitalizedFirst {
                document.remove(at: base + ["name"])
            } else {
                document.set(.string(script.name), at: base + ["name"])
            }
        }
    }
}
