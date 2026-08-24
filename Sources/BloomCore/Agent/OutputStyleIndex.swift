import Foundation

/// Finds every output style the Claude Code CLI would offer for one checkout.
///
/// This is Claude Code's list and nothing else's, for the same reason `SlashCommandIndex` is:
/// an output style is a Claude Code setting, and Codex has no equivalent to offer it to.
///
/// Three sources, later winning a name collision, which is the order the CLI resolves them in:
///
///   1. The four styles compiled into the binary, plus the default. See `OutputStyle.builtIns`.
///   2. `~/.claude/output-styles/*.md`.
///   3. `<checkout>/.claude/output-styles/*.md`.
///
/// A style file is markdown: optional YAML frontmatter carrying `name` and `description`, then the
/// prompt the style installs. Only the frontmatter is read here, because the prompt is the CLI's
/// business and a picker only needs a name and a sentence. The parsing is `SlashCommandIndex`'s,
/// not a second copy of it: a command file, a skill file and a style file are the same shape of
/// document in the same `.claude` directory, and having two frontmatter readers in one module
/// would mean two sets of bugs about folded YAML.
///
/// Plugins can carry output styles too, through `outputStylesPath` in a plugin manifest. They are
/// not read here. The plugin walk `SlashCommandIndex` does exists because a plugin's commands are
/// the bulk of most people's slash menu; nothing that has been looked at ships a style, and a
/// wrong guess about a manifest key would put names in this menu that the CLI cannot resolve.
public enum OutputStyleIndex {
    /// Everything, built in first and then the user's own, sorted by name.
    ///
    /// Synchronous and pure with respect to its arguments, so the tests can point it at a fixture
    /// tree and the app can run it on a background task.
    public static func discover(home: String, project: String?) -> [OutputStyle] {
        var found = OutputStyle.builtIns
        var known = Set(found.map(\.name))

        func add(_ styles: [OutputStyle]) {
            for style in styles where known.insert(style.name).inserted {
                found.append(style)
            }
        }

        // Built in wins a collision rather than losing it, which is the one place this differs
        // from the slash command index. A file called `Concise.md` cannot replace the style the
        // CLI compiled in, so a menu row bearing that name has to keep describing the built in
        // one. The custom file is dropped rather than shown twice under one name that the setting
        // could not tell apart anyway.
        add(styles(in: "\(home)/.claude/output-styles"))
        if let project {
            add(styles(in: "\(project)/.claude/output-styles"))
        }

        // Only the discovered tail is sorted. The built in five are in the order the CLI lists
        // them, with the default at the top, and that order is deliberate.
        let builtInCount = OutputStyle.builtIns.count
        return Array(found.prefix(builtInCount))
            + found.dropFirst(builtInCount).sorted { $0.name < $1.name }
    }

    /// Every `.md` file under one `output-styles` directory.
    ///
    /// Named by its own frontmatter where it has a `name`, and by its file otherwise, which is
    /// what the CLI does: it takes the basename with `.md` off and lets the frontmatter override.
    /// The walk is depth limited and follows symlinks, because `~/.claude` is very often a link
    /// into a dotfiles repository.
    static func styles(in directory: String) -> [OutputStyle] {
        SlashCommandIndex.walk(directory).compactMap { entry in
            guard entry.relative.hasSuffix(".md") else { return nil }
            let front = SlashCommandIndex.frontmatter(of: entry.path)
            let leaf = (entry.relative as NSString).lastPathComponent
            let stem = String(leaf.dropLast(3))
            guard let name = sanitised(front.name ?? stem) else { return nil }

            let detail = front.description.flatMap { $0.isEmpty ? nil : $0 }
            return OutputStyle(
                name: name,
                // The CLI falls back to the file's own prose here. A menu footnote is not worth
                // reading a second slice of every file for, so an undescribed style says only
                // that it is one, which is still more than a blank line.
                detail: detail ?? "A custom output style",
                isBuiltIn: false
            )
        }
    }

    /// A name that can safely become the value of a JSON setting on a command line.
    ///
    /// Looser than `SlashCommandIndex.sanitised`, which exists to produce something a person can
    /// type after a slash. An output style is never typed: it is picked from a menu and encoded
    /// into `--settings`, so spaces and capitals are fine and the only things worth refusing are
    /// the ones that would make the value unreadable or the menu unusable. Newlines and control
    /// characters would survive JSON encoding as escapes and then draw as a broken menu row.
    static func sanitised(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 120 else { return nil }
        guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return value
    }
}
