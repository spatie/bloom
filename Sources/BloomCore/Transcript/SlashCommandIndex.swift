import Foundation

/// Finds every `/command` the Claude Code CLI would resolve for one checkout.
///
/// This is Claude Code's list and nothing else's. `AgentKind.canRunWorkspaces` is true for exactly
/// one agent today, and the layout below is that agent's: a Codex or OpenCode session has its own
/// idea of what a slash means, and offering it a Claude Code skill would be offering it something
/// it cannot run. When a second backend can drive a workspace, it gets its own index rather than a
/// flag on this one.
///
/// Six sources, in the order the CLI resolves them, later winning a name collision:
///
///   1. A short built in list. The CLI's own commands live inside its binary, so they cannot be
///      read off disk; see `builtIns` for why the list is as short as it is.
///   2. `~/.claude/commands/**.md`, subfolders namespaced with a colon.
///   3. `~/.claude/skills/*/SKILL.md`. A skill is invoked with a slash exactly like a command,
///      which is why `claude --disable-slash-commands` is documented as "disable all skills".
///   4. Every enabled plugin's own `commands/` and `skills/`, namespaced `plugin:name`.
///   5. `<checkout>/.claude/commands/**.md`.
///   6. `<checkout>/.claude/skills/*/SKILL.md`.
///
/// Nothing here opens a credential. `~/.claude.json`, `~/.claude/.credentials.json` and
/// `~/.codex/auth.json` are never touched. The only files read are markdown frontmatter,
/// `settings.json` for its `enabledPlugins` key, and `installed_plugins.json` for its install
/// paths, and the only things carried out of any of them are a name and a one line description.
public enum SlashCommandIndex {
    /// How deep a `commands` or `skills` tree is followed. Enough for the deepest namespacing
    /// anyone writes, shallow enough that a stray symlink into a home directory cannot become a
    /// full disk walk.
    static let maximumDepth = 6
    /// A ceiling on one directory tree, so a misconfigured folder cannot fill the menu.
    static let maximumEntriesPerTree = 500
    /// Frontmatter lives at the top of the file, and some skills are very long.
    static let frontmatterByteLimit = 8192
    /// How much of a file the hover card will read. Enough for a screenful of prose after a long
    /// frontmatter block, and a hard stop so a skill with a megabyte of reference in it cannot be
    /// pulled into memory by a pointer resting on a chip.
    static let documentationByteLimit = 64 * 1024
    static let detailLimit = 90

    // MARK: - Entry point

    /// Everything, sorted by name.
    ///
    /// Synchronous and pure with respect to its arguments, so the tests can point it at a fixture
    /// tree and the app can run it on a background task.
    public static func discover(home: String, project: String?) -> [SlashCommand] {
        var byName: [String: SlashCommand] = [:]

        func add(_ commands: [SlashCommand]) {
            for command in commands { byName[command.name] = command }
        }

        add(builtIns)
        add(commands(in: "\(home)/.claude/commands", namespace: nil, scope: .user))
        add(skills(in: "\(home)/.claude/skills", namespace: nil, scope: .user))
        add(pluginEntries(home: home, project: project))

        if let project {
            add(commands(in: "\(project)/.claude/commands", namespace: nil, scope: .project))
            add(skills(in: "\(project)/.claude/skills", namespace: nil, scope: .project))
        }

        return byName.values.sorted { $0.name < $1.name }
    }

    // MARK: - Built in

    /// The CLI's own commands, kept by hand and kept short on purpose.
    ///
    /// They are compiled into the `claude` binary, so unlike everything else here they cannot be
    /// discovered, only asserted. Most of the CLI's built ins drive its terminal interface and
    /// mean nothing in a Bloom turn: `/vim`, `/terminal-setup`, `/statusline` and their like would
    /// be offers that go nowhere. So this is only the ones that are a prompt in their own right
    /// and that a Bloom session can actually carry out. Adding to it is a decision, not a sweep.
    public static let builtIns: [SlashCommand] = [
        SlashCommand(
            name: "code-review",
            detail: "Review the current diff, or a pull request, branch or path",
            kind: .command,
            scope: .builtIn
        ),
        SlashCommand(
            name: "compact",
            detail: "Summarise the conversation so far and continue with the summary",
            kind: .command,
            scope: .builtIn
        ),
        SlashCommand(
            name: "init",
            detail: "Write a CLAUDE.md describing this repository",
            kind: .command,
            scope: .builtIn
        ),
        SlashCommand(
            name: "pr-comments",
            detail: "Read and act on the review comments on this pull request",
            kind: .command,
            scope: .builtIn
        ),
        SlashCommand(
            name: "review",
            detail: "Review a pull request",
            kind: .command,
            scope: .builtIn
        ),
        SlashCommand(
            name: "security-review",
            detail: "Complete a security review of the pending changes on this branch",
            kind: .command,
            scope: .builtIn
        ),
        SlashCommand(
            name: "ultrareview",
            detail: "Run a cloud hosted multi agent review of this branch and print the findings",
            kind: .command,
            scope: .builtIn
        ),
    ]

    // MARK: - Command files

    /// Every `.md` under a `commands` directory, named by its path relative to that directory.
    static func commands(
        in directory: String,
        namespace: String?,
        scope: SlashCommand.Scope
    ) -> [SlashCommand] {
        walk(directory).compactMap { entry in
            guard entry.relative.hasSuffix(".md") else { return nil }
            // A command in a subfolder is namespaced with a colon, the way the CLI writes it.
            let leaf = String(entry.relative.dropLast(3)).replacing("/", with: ":")
            guard let name = qualified(leaf, namespace: namespace) else { return nil }
            let front = frontmatter(of: entry.path)
            return SlashCommand(
                name: name,
                detail: front.description ?? firstProseLine(of: entry.path),
                kind: .command,
                scope: scope,
                path: entry.path
            )
        }
    }

    // MARK: - Skill directories

    /// Every `SKILL.md` under a `skills` directory, named by its own frontmatter where it has a
    /// usable one and by its folder otherwise.
    static func skills(
        in directory: String,
        namespace: String?,
        scope: SlashCommand.Scope
    ) -> [SlashCommand] {
        skillFiles(in: directory).compactMap { entry in
            let folder = (entry.relative as NSString).deletingLastPathComponent
            guard !folder.isEmpty else { return nil }

            let front = frontmatter(of: entry.path)
            let leaf = front.name.flatMap(sanitised) ?? (folder as NSString).lastPathComponent
            guard let name = qualified(leaf, namespace: namespace) else { return nil }

            return SlashCommand(
                name: name,
                detail: front.description ?? "",
                kind: .skill,
                scope: scope,
                path: entry.path
            )
        }
    }

    /// The `SKILL.md` files directly under a skills directory, and nothing else in it.
    ///
    /// One level, which is the whole of the rule: a skill is `skills/<name>/SKILL.md` and the CLI
    /// looks no deeper. Recursing found forty extra entries on the machine this was written for,
    /// and every one of them was wrong. `~/.claude/skills/marketing` and `~/.claude/skills/music`
    /// there are whole plugins that were unpacked into the skills folder, each with a
    /// `.claude-plugin` manifest and a `skills` folder of its own. The CLI ignores both, because
    /// neither has a `SKILL.md` of its own, and so does this. A folder with a `SKILL.md` is also
    /// not descended into: the scripts and references beside it are its material, not more skills.
    static func skillFiles(in directory: String) -> [Entry] {
        guard isDirectory(directory) else { return [] }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        var found: [Entry] = []
        for name in names.sorted() {
            guard found.count < maximumEntriesPerTree else { break }
            guard !name.hasPrefix(".") else { continue }
            let folder = (directory as NSString).appendingPathComponent(name)
            guard isDirectory(folder) else { continue }
            let manifest = (folder as NSString).appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: manifest) else { continue }
            found.append(Entry(relative: "\(name)/SKILL.md", path: manifest))
        }
        return found
    }

    // MARK: - Plugins

    /// The commands and skills of every plugin that is both enabled and installed.
    ///
    /// Both halves matter. `settings.json` says which plugins count, and `installed_plugins.json`
    /// says which directory is the live one: the plugin cache keeps every version it has ever
    /// fetched side by side, and the marketplace checkouts beside it hold dozens of plugins that
    /// were never installed at all. Walking that tree without asking would offer seven copies of
    /// the same stale command.
    static func pluginEntries(home: String, project: String?) -> [SlashCommand] {
        let enabled = enabledPluginKeys(home: home, project: project)
        guard !enabled.isEmpty else { return [] }
        let installed = installPaths(home: home)

        var found: [SlashCommand] = []
        for key in enabled.sorted() {
            guard let root = installed[key] else { continue }
            // The plugin names itself; the settings key is only the fallback.
            let namespace = pluginName(at: root) ?? String(key.prefix { $0 != "@" })
            guard let namespace = sanitised(namespace) else { continue }
            found += commands(
                in: "\(root)/commands",
                namespace: namespace,
                scope: .plugin(namespace)
            )
            found += skills(
                in: "\(root)/skills",
                namespace: namespace,
                scope: .plugin(namespace)
            )
        }
        return found
    }

    /// The `enabledPlugins` map, user settings first and this repository's settings on top.
    ///
    /// `settings.local.json` is read last because that is the file a person uses to turn one
    /// plugin off for one checkout, and it has to be able to win.
    static func enabledPluginKeys(home: String, project: String?) -> Set<String> {
        var flags: [String: Bool] = [:]

        var files = ["\(home)/.claude/settings.json"]
        if let project {
            files.append("\(project)/.claude/settings.json")
            files.append("\(project)/.claude/settings.local.json")
        }

        for file in files {
            guard let object = json(at: file),
                  let plugins = object["enabledPlugins"] as? [String: Any] else { continue }
            for (key, value) in plugins {
                guard let enabled = value as? Bool else { continue }
                flags[key] = enabled
            }
        }

        return Set(flags.filter(\.value).map(\.key))
    }

    /// Where each installed plugin actually lives, keyed the same way `enabledPlugins` keys it.
    static func installPaths(home: String) -> [String: String] {
        let file = "\(home)/.claude/plugins/installed_plugins.json"
        guard let object = json(at: file),
              let plugins = object["plugins"] as? [String: Any] else { return [:] }

        var paths: [String: String] = [:]
        for (key, value) in plugins {
            guard let installs = value as? [[String: Any]] else { continue }
            let candidates = installs.compactMap { $0["installPath"] as? String }
            // A version that has been removed from the cache is still listed, so the first one
            // that is really there wins over the first one that is merely written down.
            paths[key] = candidates.first { isDirectory($0) } ?? candidates.first
        }
        return paths
    }

    static func pluginName(at root: String) -> String? {
        guard let object = json(at: "\(root)/.claude-plugin/plugin.json") else { return nil }
        return (object["name"] as? String).flatMap(sanitised)
    }

    // MARK: - Names

    static func qualified(_ leaf: String, namespace: String?) -> String? {
        guard let leaf = sanitised(leaf) else { return nil }
        guard let namespace else { return leaf }
        return "\(namespace):\(leaf)"
    }

    /// A name that can actually be typed after a slash. Anything else is a file that was never
    /// meant to be a command, and offering it would insert a draft the CLI cannot resolve.
    static func sanitised(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 120 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.:")
        guard value.lowercased().unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return value
    }

    // MARK: - Frontmatter

    struct Frontmatter {
        var name: String?
        var description: String?
    }

    /// Reads `name:` and `description:` out of the YAML block at the top of a markdown file.
    ///
    /// Only the head of the file is read. A skill can be tens of kilobytes of prose and none of it
    /// after the closing `---` is any of the menu's business.
    static func frontmatter(of path: String) -> Frontmatter {
        guard let head = head(of: path) else { return Frontmatter() }
        var lines = head.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return Frontmatter() }
        lines.removeFirst()

        var block: [String] = []
        var closed = false
        while let line = lines.first {
            lines.removeFirst()
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                closed = true
                break
            }
            block.append(line)
        }
        // An unterminated block means the read was cut off mid frontmatter, and treating the whole
        // of the file as YAML would put a paragraph of prose in the description column.
        guard closed else { return Frontmatter() }

        return Frontmatter(
            name: value(of: "name", in: block).map(clean),
            description: value(of: "description", in: block).map(clean)
        )
    }

    /// One key out of a YAML block, including the folded and literal forms a long description is
    /// usually written in.
    static func value(of key: String, in block: [String]) -> String? {
        guard let index = block.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("\(key):")
        }) else { return nil }

        let line = block[index].trimmingCharacters(in: .whitespaces)
        var inline = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        if inline == ">" || inline == ">-" || inline == "|" || inline == "|-" { inline = "" }
        guard inline.isEmpty else { return inline }

        // A folded value continues on the indented lines under it.
        var continuation: [String] = []
        for line in block[block.index(after: index)...] {
            guard line.hasPrefix(" ") || line.hasPrefix("\t") else { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            continuation.append(trimmed)
        }
        return continuation.isEmpty ? nil : continuation.joined(separator: " ")
    }

    /// The first line of real prose, for a command file that carries no frontmatter at all. A
    /// heading is a better summary than an empty column.
    static func firstProseLine(of path: String) -> String {
        guard let head = head(of: path) else { return "" }
        var lines = head.components(separatedBy: .newlines)

        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            lines.removeFirst()
            while let line = lines.first {
                lines.removeFirst()
                if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            return clean(String(trimmed.drop { $0 == "#" }))
        }
        return ""
    }

    // MARK: - What a command says for itself

    /// The prose of a command file, with its YAML frontmatter taken off the top.
    public struct Documentation: Equatable, Sendable {
        public var lines: [String]
        /// Whether there was more of the file than fitted.
        public var truncated: Bool

        public init(lines: [String], truncated: Bool) {
            self.lines = lines
            self.truncated = truncated
        }
    }

    /// The head of what a command actually tells the agent to do, for the hover card.
    ///
    /// The frontmatter is dropped rather than shown. It is the description over again, and a
    /// skill's description is routinely a paragraph long: printed at the top of the card it would
    /// fill the card twice over with the one line already set above it. What is worth glancing at
    /// is the instruction underneath.
    ///
    /// Capped in both directions by the caller, which passes the same limits the file preview
    /// uses, and the whole read is bounded before any of that: a skill can be tens of kilobytes
    /// and none of it past the first screenful is a hover card's business.
    public static func documentation(of path: String, lines limit: Int, columns: Int) -> Documentation? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: documentationByteLimit), !data.isEmpty else {
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)

        var lines = text.components(separatedBy: .newlines)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            lines.removeFirst()
            while let line = lines.first {
                lines.removeFirst()
                if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            }
        }

        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return nil }

        let truncated = lines.count > limit
        let head = lines.prefix(limit).map { line -> String in
            // Tabs drawn at their own width make one long line as wide as the screen.
            let expanded = line.replacing("\t", with: "    ")
            return expanded.count > columns
                ? String(expanded.prefix(columns)) + "\u{2026}"
                : expanded
        }
        return Documentation(lines: head, truncated: truncated)
    }

    static func clean(_ text: String) -> String {
        var value = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing("\n", with: " ")
        if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count > detailLimit ? String(value.prefix(detailLimit - 1)) + "\u{2026}" : value
    }

    // MARK: - Disk

    struct Entry {
        /// Path relative to the directory the walk started at, with `/` separators.
        var relative: String
        var path: String
    }

    /// A depth limited recursive walk that follows symlinks.
    ///
    /// Written out rather than handed to `FileManager.enumerator`, because the directories this
    /// has to read are routinely symlinks: `~/.claude/skills` is very often a link into a dotfiles
    /// repository, and an enumerator that will not step through one finds nothing at all there.
    /// Following links means cycles are possible, so every directory is recorded by its resolved
    /// path and visited once.
    static func walk(_ directory: String) -> [Entry] {
        guard isDirectory(directory) else { return [] }

        var found: [Entry] = []
        var visited: Set<String> = []

        func descend(_ path: String, relative: String, depth: Int) {
            guard depth <= maximumDepth, found.count < maximumEntriesPerTree else { return }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard visited.insert(resolved).inserted else { return }

            let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            for name in names.sorted() {
                guard found.count < maximumEntriesPerTree else { return }
                guard !name.hasPrefix(".") else { continue }
                let child = (path as NSString).appendingPathComponent(name)
                let childRelative = relative.isEmpty ? name : "\(relative)/\(name)"
                if isDirectory(child) {
                    descend(child, relative: childRelative, depth: depth + 1)
                } else {
                    found.append(Entry(relative: childRelative, path: child))
                }
            }
        }

        descend(directory, relative: "", depth: 0)
        return found
    }

    /// True for a directory, and for a symlink that resolves to one.
    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// The head of a file as text, never the whole of it.
    static func head(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: frontmatterByteLimit), !data.isEmpty else {
            return nil
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        // A read cut mid character is not a reason to lose the file.
        return String(decoding: data, as: UTF8.self)
    }

    static func json(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
