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

    public var key: SettingsKey {
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
/// The settings a repository has are already stated in files: `<repo>/.bloom/settings.toml` and
/// its `.local` sibling, plus the `.conductor` pair of the same shape, which is where a
/// repository already configured for Conductor keeps them. Bloom reads all four. The obvious way
/// to make the screen editable is to keep overrides in Bloom's own database and layer them on
/// top, and that was rejected:
///
/// * The value would then exist twice, and the copy that wins would be the invisible one. A
///   teammate who fixes `scripts.setup` in the committed file, and a user whose app is quietly
///   overriding it, would disagree forever with nothing on screen to explain why.
/// * The scripts have to run for `git` worktrees created by other tools and by Conductor itself.
///   A value only Bloom's database knows is a value nothing else can honour.
/// * "Edit it in the app, then look at the file" has to show the change. That is only true if the
///   app edits the file.
///
/// So the app edits the files, and the only question left is which one. The answer is: **Bloom's
/// own file, at the tier the value came from**. Change the setup script and the line that changes
/// is the line you would have changed by hand, ready to be committed or reverted with `git`.
///
/// The one value that is not edited where it was found is one that came from `.conductor`. Bloom
/// reads that folder so a repository already set up for Conductor works here with nothing to
/// configure; it does not follow that Bloom should maintain another product's file. So the edit
/// goes to `.bloom`, which outranks it, and the old line is left exactly as the team committed
/// it. That does leave the same setting stated in two files, which is the one thing this whole
/// design is against, so it is never done quietly: the screen says "Read from A, saved to B" for
/// as long as both exist. See `SettingsDestinationLabel`.
///
/// A setting that no repository file states yet goes to `defaultFile`, and the screen names that
/// path next to the field before anything is written, so the destination is never a surprise.
public enum SettingsWriter {
    /// The file an edit to `key` will be written to.
    ///
    /// Always one of Bloom's own two files. A value read out of `.conductor/settings.toml` is not
    /// edited where it was found: Bloom reads that folder so an existing Conductor repository
    /// works with nothing to configure, which is a courtesy on the way in and not a claim on the
    /// folder. Writing there would make Bloom quietly maintain another product's configuration.
    ///
    /// A value only a machine-wide file states is not edited in place either, for the older
    /// reason: this screen is about one repository, and rewriting `~/.bloom/settings.toml` from it
    /// would change every other repository on the machine.
    ///
    /// The tier is kept. A value that came from a `.local` file is written to Bloom's `.local`
    /// file rather than to the shared one, because the shared file ranks BELOW every `.local` one
    /// (see `SettingsLoader.repoPaths`): writing a `.conductor/settings.local.toml` value into
    /// `.bloom/settings.toml` would leave the old value still winning, and the edit would look
    /// like it did nothing.
    public static func destination(for key: SettingsKey, in settings: RepoSettings, repo: String) -> String {
        guard let origin = settings.origins[key],
              SettingsLoader.repoPaths(repo: repo).contains(origin)
        else { return defaultFile(repo: repo) }

        return bloomFile(matching: origin, repo: repo)
    }

    /// Bloom's file at the same tier as `path`: shared for shared, `.local` for `.local`.
    static func bloomFile(matching path: String, repo: String) -> String {
        let name = (path as NSString).lastPathComponent
        return (repo as NSString).appendingPathComponent(".bloom/\(name)")
    }

    /// Where a setting goes when no repository file states it yet.
    ///
    /// The shared, committable file rather than the `.local` one: a setup script or a list of
    /// files to copy is nearly always something the whole team needs, and a value that should stay
    /// on one machine can be moved to `settings.local.toml` by hand afterwards.
    public static func defaultFile(repo: String) -> String {
        (repo as NSString).appendingPathComponent(".bloom/settings.toml")
    }

    /// Bloom's folder in a repository, made ready the first time something is written into it.
    ///
    /// `settings.toml` is meant to be committed. A setup script that exists on one machine is not
    /// a setup script the team has, and sharing it is the whole reason it lives in the repository
    /// rather than in Bloom's database. `settings.local.toml` is the opposite: it is where a value
    /// that must not leave this machine goes, so the ignore rule for it is written beside it once,
    /// rather than left for somebody to discover after committing a password.
    ///
    /// Only ever written when the folder is being created. A `.gitignore` a user has since edited
    /// is theirs, and nothing here rewrites it.
    static func prepareFolder(for path: String, repo: String) {
        let manager = FileManager.default
        let folder = (path as NSString).deletingLastPathComponent
        guard folder == (repo as NSString).appendingPathComponent(".bloom"),
              !manager.fileExists(atPath: folder)
        else { return }

        try? manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let ignore = (folder as NSString).appendingPathComponent(".gitignore")
        try? "settings.local.toml\n".write(toFile: ignore, atomically: true, encoding: .utf8)
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
            for edit in fileEdits {
                apply(edit, to: &document, overriding: overrides(edit.key, in: settings, file: path))
            }
            guard document.text != before else { continue }
            // A file that did not exist and would still say nothing is not worth creating.
            if !document.exists, document.isEmpty { continue }
            prepareFolder(for: path, repo: repo)
            try document.write(to: path)
            written.append(path)
        }
        return written
    }

    /// Whether this edit has to out-argue a value some other file still states.
    ///
    /// Only ever true because Bloom writes to `.bloom` and reads `.conductor` as well. Deleting a
    /// line from `.bloom/settings.toml` would leave the `.conductor` one showing through, so
    /// "clear the setup script" has to be written as a statement rather than as an absence.
    private static func overrides(_ key: SettingsKey, in settings: RepoSettings, file: String) -> Bool {
        guard let origin = settings.origins[key] else { return false }
        return origin != file
    }

    static func apply(
        _ edit: SettingsEdit, to document: inout SettingsDocument, overriding: Bool = false
    ) {
        switch edit {
        case .setupScript(let script):
            set(script, at: SettingsKey.setupScript.path, in: &document, overriding: overriding)
        case .archiveScript(let script):
            set(script, at: SettingsKey.archiveScript.path, in: &document, overriding: overriding)
        case .runMode(let mode):
            document.set(.string(mode), at: SettingsKey.runMode.path)
        case .branchPrefix(let prefix):
            set(prefix, at: SettingsKey.branchPrefix.path, in: &document, overriding: overriding)
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

    private static func set(
        _ value: String?, at path: [String], in document: inout SettingsDocument,
        overriding: Bool = false
    ) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            document.set(.string(trimmed), at: path)
        } else if overriding {
            // An empty string rather than no line at all. See `overrides`, and the loader, which
            // reads a stated empty script as "there is none" rather than as nothing said.
            document.set(.string(""), at: path)
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
