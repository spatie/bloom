import Foundation

/// The two lists a settings file can state, run scripts and quick prompts, read entry by entry.
///
/// Apart from the scalar settings in `SettingsLoader.apply` because these are the part of a file
/// that can be half right. A scalar with the wrong type is simply not read, which is what every
/// setting here has always done. A list is different: one bad entry must not take its neighbours
/// with it, and it must not vanish silently either, because the owner will go looking for the run
/// script a teammate said they had added. So each entry is checked on its own, skipped on its own,
/// and reported as a `SettingsIssue`.
///
/// **A key nobody here knows is ignored, and says nothing.** A file written for a newer Bloom, or
/// for Conductor, will carry keys this build has never heard of, and reporting each of them would
/// be a warning on every project for doing nothing wrong. Only a key this build reads, holding
/// something it cannot use, is an issue.
extension SettingsLoader {
    // MARK: - Run scripts

    static func applyRunScripts(
        _ toml: TOMLValue, outline: TOMLOutline?, from source: String,
        to settings: inout RepoSettings, repo: String
    ) {
        guard let run = toml["scripts.run"] else { return }
        let base = SettingsKey.runScripts.path

        switch run {
        case .string(let command):
            // An empty string has only ever been ignored here, and a file that says `run = ""`
            // is not saying anything worth a sentence.
            guard !command.isEmpty else { return }
            settings.runScripts = [RunScript(id: "run", name: "Run", command: command)]
            settings.origins[.runScripts] = source

        case .table(let named):
            // File order, which is the order the `+` menu lists them in. It used to be sorted by
            // id, because the parsed table is a dictionary. See `TOMLOutline`.
            let keys = outline?.keys(of: named, at: base) ?? named.keys.sorted()
            var scripts: [RunScript] = []
            var files: [ScriptLocation: ScriptFile] = [:]
            // Name, trimmed and lowercased, to the id that took it first.
            var taken: [String: String] = [:]

            for key in keys {
                guard let value = named[key] else { continue }
                let line = outline?.line(of: base + [key])
                func report(_ message: String) {
                    settings.issues.append(SettingsIssue(
                        path: source, message: "Run script \u{201C}\(key)\u{201D} \(message)",
                        entry: .runScript(key), line: line
                    ))
                }

                let read: RunScriptEntry
                switch readRunScript(key: key, value: value, repo: repo) {
                case .success(let entry): read = entry
                case .failure(let problem):
                    report("was skipped: \(problem.reason).")
                    continue
                }

                // Two rows called the same thing in one menu is a menu nobody can pick from with
                // confidence. The first stays, because it is the one the file put first.
                let normalised = read.script.name
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let first = taken[normalised] {
                    report(
                        "was skipped: run script \u{201C}\(first)\u{201D} already has the name "
                            + "\u{201C}\(read.script.name)\u{201D}."
                    )
                    continue
                }
                taken[normalised] = key

                if let file = read.file {
                    files[.run(key)] = file
                    // Kept rather than skipped. The settings window already shows a missing file
                    // as missing, and dropping the row would leave nothing there to fix it from.
                    if file.isMissing {
                        report("cannot run: \(file.path) does not exist.")
                    }
                }
                scripts.append(read.script)
            }

            if !scripts.isEmpty {
                settings.runScripts = scripts
                for (location, file) in files { settings.scriptFiles[location] = file }
                settings.origins[.runScripts] = source
            }

        default:
            settings.issues.append(SettingsIssue(
                path: source,
                message: "Run scripts were skipped: scripts.run has to be a command or a table of scripts.",
                entry: .file,
                line: outline?.line(of: base)
            ))
        }
    }

    struct RunScriptEntry {
        var script: RunScript
        var file: ScriptFile?
    }

    struct EntryProblem: Error {
        /// The end of a sentence that starts with the entry's name and "was skipped:".
        var reason: String
    }

    /// One `[scripts.run.<key>]` table, or `scripts.run.<key> = "command"`, or why not.
    static func readRunScript(
        key: String, value: TOMLValue, repo: String
    ) -> Result<RunScriptEntry, EntryProblem> {
        let table: [String: TOMLValue]
        switch value {
        case .string(let command):
            guard !command.isEmpty else { return .failure(EntryProblem(reason: "it has no command")) }
            return .success(RunScriptEntry(
                script: RunScript(id: key, name: key.capitalizedFirst, command: command), file: nil
            ))
        case .table(let fields):
            table = fields
        default:
            return .failure(EntryProblem(reason: "it has to be a table or a command in quotes"))
        }

        let name: String?
        let command: String?
        let file: String?
        let icon: String?
        let autostart: Bool?
        do throws(EntryProblem) {
            name = try text(table["name"], "name")
            command = try text(table["command"], "command")
            file = try text(table["file"], "file")
            icon = try text(table["icon"], "icon")
            autostart = try flag(table["autostart"], "autostart")
        } catch {
            return .failure(error)
        }

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedName = trimmedName.isEmpty ? key.capitalizedFirst : trimmedName
        let trimmedIcon = icon?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedIcon = trimmedIcon.isEmpty ? nil : trimmedIcon

        // A run script is usually one command and stays a string. It gets a file of its own on
        // the same terms as the setup script: when it is long enough to be a program. See
        // `SettingsWriter.wantsAFile`. The file wins over `command` inside one table.
        if let file, !file.isEmpty {
            let text = try? String(contentsOfFile: resolve(file, repo: repo), encoding: .utf8)
            return .success(RunScriptEntry(
                script: RunScript(
                    id: key, name: resolvedName, command: text ?? "",
                    icon: resolvedIcon, autostart: autostart ?? false
                ),
                file: ScriptFile(path: file, isMissing: text == nil)
            ))
        }
        guard let command, !command.isEmpty else {
            return .failure(EntryProblem(reason: "it has no command"))
        }
        return .success(RunScriptEntry(
            script: RunScript(
                id: key, name: resolvedName, command: command,
                icon: resolvedIcon, autostart: autostart ?? false
            ),
            file: nil
        ))
    }

    // MARK: - Quick prompts

    /// `[[quick_prompts]]`, from one of the repository's own files.
    ///
    /// The last file that states the key replaces the list, as it does for run scripts, and a
    /// stated list replaces it even when nothing in it could be read. That is the only way a
    /// `.local` file can say "none of the team's prompts on this machine", and a list that came out
    /// empty because every entry was wrong has an issue per entry saying so.
    static func applyQuickPrompts(
        _ toml: TOMLValue, outline: TOMLOutline?, from source: String,
        to settings: inout RepoSettings
    ) {
        guard let stated = toml["quick_prompts"] else { return }
        guard case .array(let entries) = stated else {
            settings.issues.append(SettingsIssue(
                path: source,
                message: "Quick prompts were skipped: each one has to be a [[quick_prompts]] table.",
                entry: .file,
                line: outline?.line(of: ["quick_prompts"])
            ))
            return
        }

        var prompts: [ProjectQuickPrompt] = []
        var taken: Set<String> = []
        for (index, entry) in entries.enumerated() {
            let line = outline?.line(of: ["quick_prompts", "\(index)"])
            let fields = entry.tableValue
            let usableName = (fields?["name"]?.stringValue)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            func report(_ message: String) {
                let label = usableName.map { "Quick prompt \u{201C}\($0)\u{201D}" }
                    ?? "Quick prompt \(index + 1)"
                settings.issues.append(SettingsIssue(
                    path: source, message: "\(label) \(message)",
                    entry: .quickPrompt(index: index, name: usableName), line: line
                ))
            }

            guard let fields else {
                report("was skipped: it has to be a table.")
                continue
            }
            switch readQuickPrompt(fields, source: source) {
            case .failure(let problem):
                report("was skipped: \(problem.reason).")
            case .success(let prompt):
                // Deliberately not honoured, and said so rather than quietly dropped: see
                // `ProjectQuickPrompt`. The prompt itself is still offered, composing.
                if fields["send_immediately"] != nil {
                    report("will not send on its own: send_immediately is not supported in a shared settings file.")
                }
                guard taken.insert(prompt.id).inserted else {
                    report("was skipped: another quick prompt already has that name.")
                    continue
                }
                // Kept, drawn with the default. `QuickPromptMark` only draws symbols on the
                // picker's list, because a name macOS does not know draws an empty box, so a
                // symbol outside it would otherwise be swapped for the default without a word.
                if let stated = fields["symbol"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !stated.isEmpty, prompt.symbol != stated {
                    report("shows the default symbol: \u{201C}\(stated)\u{201D} is not one Bloom offers.")
                }
                prompts.append(prompt)
            }
        }
        settings.quickPrompts = prompts
    }

    static func readQuickPrompt(
        _ fields: [String: TOMLValue], source: String
    ) -> Result<ProjectQuickPrompt, EntryProblem> {
        let name: String?
        let prompt: String?
        let symbol: String?
        let newChat: Bool?
        do throws(EntryProblem) {
            name = try text(fields["name"], "name")
            prompt = try text(fields["prompt"], "prompt")
            symbol = try text(fields["symbol"], "symbol")
            newChat = try flag(fields["new_chat"], "new_chat")
        } catch {
            return .failure(error)
        }

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedName.isEmpty else { return .failure(EntryProblem(reason: "it has no name")) }
        guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(EntryProblem(reason: "it has no prompt"))
        }
        return .success(ProjectQuickPrompt(
            name: trimmedName,
            text: prompt,
            // Resolved on the way in, so the panel is never handed a name that draws an empty box.
            symbol: QuickPrompt.resolvedSymbol(symbol ?? QuickPrompt.defaultSymbol),
            opensNewChat: newChat ?? false,
            source: source
        ))
    }

    // MARK: - Typed reads

    /// A value that is either absent or text. Anything else is a mistake worth a sentence.
    private static func text(_ value: TOMLValue?, _ key: String) throws(EntryProblem) -> String? {
        guard let value else { return nil }
        guard let text = value.stringValue else {
            throw EntryProblem(reason: "\(key) has to be text in quotes")
        }
        return text
    }

    private static func flag(_ value: TOMLValue?, _ key: String) throws(EntryProblem) -> Bool? {
        guard let value else { return nil }
        guard let flag = value.boolValue else {
            throw EntryProblem(reason: "\(key) has to be true or false")
        }
        return flag
    }
}
