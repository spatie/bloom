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
    /// `.bloom` is meant to be committed, and that is the whole point of it. `settings.toml` and
    /// the scripts beside it are what the team shares: a setup script that exists on one machine
    /// is not a setup script the team has, and sharing it is why it lives in the repository rather
    /// than in Bloom's database.
    ///
    /// The `.local` half is the opposite. `settings.local.toml` is where a value that must not
    /// leave this machine goes, and a personal setup script named by it is written as
    /// `setup.local.sh` rather than over the shared `setup.sh`. So the ignore rule covers both
    /// spellings and is written beside them once, rather than left for somebody to discover after
    /// committing a password.
    ///
    /// Written when there is no ignore file yet, rather than only when the folder is new. A
    /// `.gitignore` that is already there is somebody's, and nothing here rewrites it.
    ///
    /// The distinction matters because `.bloom` is routinely brought into existence by something
    /// that has no business writing the team's ignore rules: `WorktreeScratch` makes
    /// `.bloom/attachments` and `.bloom/scratch` inside it, and those folders must add nothing to
    /// the user's repository. Keying off the folder meant the first attachment in a repository
    /// permanently stopped the ignore rules from ever being laid down, and the password
    /// `settings.local.toml` exists to protect was one commit away.
    static func prepareFolder(for path: String, repo: String) {
        let manager = FileManager.default
        let folder = (path as NSString).deletingLastPathComponent
        guard folder == (repo as NSString).appendingPathComponent(".bloom") else { return }

        let ignore = (folder as NSString).appendingPathComponent(".gitignore")
        guard !manager.fileExists(atPath: ignore) else { return }

        try? manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? "settings.local.toml\n*.local.sh\n".write(
            toFile: ignore, atomically: true, encoding: .utf8
        )
    }

    // MARK: - Scripts as files

    /// Whether this script wants a file of its own rather than a string in the settings file.
    ///
    /// A program does; one command does not. `npm run dev` inside `.bloom/run-dev.sh`, under a
    /// shebang, is ceremony around three words, and it makes the settings file less readable
    /// rather than more. A forty line setup script is the opposite case in every way: it has a
    /// shebang, it wants `shellcheck`, and somebody will want to run it straight from a terminal
    /// while they are writing it.
    ///
    /// So the line is drawn where the difference actually is: more than one line, or a shebang.
    /// Both are what a person would have used to decide the same thing by hand.
    static func wantsAFile(_ script: String) -> Bool {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.contains("\n") || trimmed.hasPrefix("#!")
    }

    /// The file a script of this kind is created as, when it has none yet.
    ///
    /// Beside the settings file that points at it, because a folder holding a settings file and
    /// the scripts it names is one thing to read and one thing to commit.
    ///
    /// `local` puts `.local` in the name, to match the settings file the pointer is being written
    /// to. A personal setup script must not be written over the one the team shares, and
    /// `.bloom/.gitignore` keeps `*.local.sh` out of `git` for the same reason it keeps
    /// `settings.local.toml` out.
    static func defaultScriptPath(for location: ScriptLocation, local: Bool) -> String {
        let name = switch location {
        case .setup: "setup"
        case .archive: "archive"
        case .run(let id): "run-\(id)"
        }
        return ".bloom/\(name)\(local ? ".local" : "").sh"
    }

    /// The settings key a script of this kind is stated under, which is what decides the file the
    /// pointer to it lands in.
    static func key(for location: ScriptLocation) -> SettingsKey {
        switch location {
        case .setup: .setupScript
        case .archive: .archiveScript
        case .run: .runScripts
        }
    }

    /// Where this script would be stored if it were saved right now, repository-relative, or `nil`
    /// when it belongs in the settings file as a string.
    ///
    /// Three rules, in this order.
    ///
    /// 1. A script that already has a file keeps it, at exactly the path the settings file states.
    ///    Somebody who moved theirs to `bin/dev-setup.sh` by hand and pointed the settings file at
    ///    it is not quietly repointed at Bloom's own name for it, and a file that has gone missing
    ///    is rewritten where it was rather than beside where it was.
    /// 2. A script long enough to be a program gets a file. See `wantsAFile`.
    /// 3. Everything else stays inline, which is where one command reads best.
    ///
    /// The settings window asks this too, so the path named under the field is the path Save will
    /// actually use.
    public static func scriptFile(
        for location: ScriptLocation, script: String, in settings: RepoSettings, repo: String
    ) -> String? {
        // Nothing left to store. The pointer comes out of the settings file, and any file it named
        // is left where it is: deleting a file somebody may have edited by hand, or committed, is
        // not Bloom's call to make from a cleared text box.
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let stated = settings.scriptFiles[location]?.path, !stated.isEmpty { return stated }
        guard wantsAFile(script) else { return nil }

        let file = destination(for: key(for: location), in: settings, repo: repo)
        return defaultScriptPath(for: location, local: file.hasSuffix(".local.toml"))
    }

    /// Writes one script out as an executable file.
    ///
    /// 0755 on purpose. A file that opens with `#!/bin/zsh` and cannot be run is a worse lie than
    /// a string was, and `git` carries the executable bit, so the mode travels with the file to
    /// everyone else on the team.
    static func writeScript(_ script: String, to path: String, repo: String) throws {
        let full = SettingsLoader.resolve(path, repo: repo)
        prepareFolder(for: full, repo: repo)
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )

        // A trailing newline, because every tool that reads a text file expects one and because
        // the editor's own buffer usually has one anyway.
        var text = script
        if !text.hasSuffix("\n") { text += "\n" }
        try text.write(toFile: full, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: full)
    }

    /// The script files an edit implies, written out before any TOML is touched.
    ///
    /// Separate from `apply` because only this layer knows the repository, and done first because
    /// a settings file must never come to point at a script that failed to be written.
    private static func scriptFiles(
        for edits: [SettingsEdit], repo: String, settings: RepoSettings
    ) throws -> [SettingsKey: String] {
        var result: [SettingsKey: String] = [:]
        for edit in edits {
            let location: ScriptLocation
            let script: String
            switch edit {
            case .setupScript(let text): location = .setup; script = text ?? ""
            case .archiveScript(let text): location = .archive; script = text ?? ""
            default: continue
            }
            guard let path = scriptFile(for: location, script: script, in: settings, repo: repo)
            else { continue }
            try writeScript(script, to: path, repo: repo)
            result[edit.key] = path
        }
        return result
    }

    /// The same for run scripts, keyed by table name. Only the ones that want a file appear; the
    /// rest stay `command = "..."` in the settings file, which is where one line reads best.
    private static func runScriptFiles(
        for edits: [SettingsEdit], repo: String, settings: RepoSettings
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        for case .runScripts(let scripts) in edits {
            for script in scripts {
                guard let path = scriptFile(
                    for: .run(script.id), script: script.command, in: settings, repo: repo
                ) else { continue }
                try writeScript(script.command, to: path, repo: repo)
                result[script.id] = path
            }
        }
        return result
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
        // Before the settings files, so a settings file can never come to point at a script that
        // was not written.
        let scripts = try scriptFiles(for: edits, repo: repo, settings: settings)
        let runFiles = try runScriptFiles(for: edits, repo: repo, settings: settings)

        var byFile: [String: [SettingsEdit]] = [:]
        for edit in edits {
            byFile[destination(for: edit.key, in: settings, repo: repo), default: []].append(edit)
        }

        var written: [String] = []
        for (path, fileEdits) in byFile.sorted(by: { $0.key < $1.key }) {
            var document = SettingsDocument(contentsOf: path)
            let before = document.text
            for edit in fileEdits {
                apply(
                    edit,
                    to: &document,
                    overriding: overrides(edit.key, in: settings, file: path),
                    scriptFile: scripts[edit.key],
                    runFiles: runFiles
                )
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
        _ edit: SettingsEdit, to document: inout SettingsDocument, overriding: Bool = false,
        scriptFile: String? = nil, runFiles: [String: String] = [:]
    ) {
        switch edit {
        case .setupScript(let script):
            setScript(
                script, inline: SettingsKey.setupScript.path, file: Self.setupFilePath,
                pointingAt: scriptFile, in: &document, overriding: overriding
            )
        case .archiveScript(let script):
            setScript(
                script, inline: SettingsKey.archiveScript.path, file: Self.archiveFilePath,
                pointingAt: scriptFile, in: &document, overriding: overriding
            )
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
            writeRunScripts(scripts, to: &document, files: runFiles)
        }
    }

    /// The key that names a script's file, beside the one that used to hold its text.
    static let setupFilePath = ["scripts", "setup_file"]
    static let archiveFilePath = ["scripts", "archive_file"]

    /// Writes a script into the settings file as either a pointer or a string, and takes the other
    /// form out in the same pass.
    ///
    /// Both forms present would be a file stating the same script twice, with the reader's
    /// preference deciding which one won: exactly the invisible disagreement this whole design is
    /// against. So whichever form is not being used is removed.
    private static func setScript(
        _ value: String?, inline: [String], file: [String], pointingAt path: String?,
        in document: inout SettingsDocument, overriding: Bool
    ) {
        if let path {
            document.remove(at: inline)
            document.set(.string(path), at: file)
            return
        }
        document.remove(at: file)
        set(value, at: inline, in: &document, overriding: overriding)
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
    private static func writeRunScripts(
        _ scripts: [RunScript], to document: inout SettingsDocument, files: [String: String] = [:]
    ) {
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
            if let path = files[script.id] {
                document.remove(at: base + ["command"])
                document.set(.string(path), at: base + ["file"])
            } else {
                document.remove(at: base + ["file"])
                document.set(.string(script.command), at: base + ["command"])
            }
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
