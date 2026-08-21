import Testing
import Foundation
@testable import BloomCore

/// What the `/` menu offers, and in what order.
///
/// Every one of these builds a whole `~/.claude` and a whole checkout in the test's own scratch
/// directory and points the index at it. Nothing here reads the machine it runs on, which is the
/// only way the answers can be pinned: the real tree changes whenever a plugin updates.
@Suite("Slash commands", .scratchDirectory)
struct SlashCommandTests {
    // MARK: - Building a tree

    /// A `~/.claude` and a checkout, written a file at a time.
    struct Tree {
        let home: String
        let project: String

        init() throws {
            home = TestScratch.unique("home")
            project = TestScratch.unique("project")
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        }

        @discardableResult
        func write(_ relative: String, _ contents: String, under root: String? = nil) throws -> String {
            let path = relative.hasPrefix("/")
                ? relative
                : ((root ?? home) as NSString).appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try contents.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        }

        func skill(_ relative: String, name: String, description: String, under root: String? = nil) throws {
            try write(
                "\(relative)/SKILL.md",
                "---\nname: \(name)\ndescription: \(description)\n---\n\n# \(name)\n",
                under: root
            )
        }

        func discover() -> [SlashCommand] {
            SlashCommandIndex.discover(home: home, project: project)
        }

        func names() -> [String] {
            discover().map(\.name)
        }
    }

    // MARK: - The sources

    @Test("a user command file becomes a command")
    func userCommands() throws {
        let tree = try Tree()
        try tree.write(".claude/commands/commit.md", "---\ndescription: Write a commit\n---\n\nbody\n")

        let found = try #require(tree.discover().first { $0.name == "commit" })
        #expect(found.detail == "Write a commit")
        #expect(found.scope == .user)
        #expect(found.kind == .command)
    }

    @Test("a command in a subfolder is namespaced with a colon")
    func namespacedCommands() throws {
        let tree = try Tree()
        try tree.write(".claude/commands/git/commit.md", "# Commit\n")

        #expect(tree.names().contains("git:commit"))
    }

    @Test("a user skill becomes a command, which is the whole of the bug")
    func userSkills() throws {
        let tree = try Tree()
        try tree.skill(".claude/skills/review-pr", name: "review-pr", description: "Review a pull request")

        let found = try #require(tree.discover().first { $0.name == "review-pr" })
        #expect(found.detail == "Review a pull request")
        #expect(found.kind == .skill)
        #expect(found.scope == .user)
    }

    @Test("a skills directory that is a symlink is still read")
    func skillsThroughASymlink() throws {
        let tree = try Tree()
        // Exactly the shape on the machine this was written for: ~/.claude/skills points into a
        // dotfiles repository, and an enumerator that will not step through a link finds nothing.
        let real = TestScratch.unique("dotfiles-skills")
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try tree.skill("flare", name: "flare", description: "Manage Flare", under: real)

        try FileManager.default.createDirectory(
            atPath: "\(tree.home)/.claude",
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: "\(tree.home)/.claude/skills",
            withDestinationPath: real
        )

        #expect(tree.names().contains("flare"))
    }

    @Test("a whole plugin unpacked into the skills folder is not mistaken for forty skills")
    func skillsAreOneLevelDeep() throws {
        let tree = try Tree()
        try tree.skill(".claude/skills/flare", name: "flare", description: "Manage Flare")
        // Exactly what was found in the real tree: a plugin, manifest and all, sitting where a
        // skill folder should be. The CLI ignores it because it has no SKILL.md of its own.
        try tree.write(".claude/skills/marketing/.claude-plugin/plugin.json", #"{"name": "marketing"}"#)
        try tree.skill(".claude/skills/marketing/skills/cold-email", name: "cold-email", description: "Write one")
        // And the material beside a real skill is material, not more skills.
        try tree.skill(".claude/skills/flare/examples/sample", name: "sample", description: "Not a skill")

        let names = tree.names()
        #expect(names.contains("flare"))
        #expect(!names.contains("cold-email"))
        #expect(!names.contains("marketing"))
        #expect(!names.contains("sample"))
    }

    @Test("this repository's own commands and skills are offered, and badged")
    func projectSources() throws {
        let tree = try Tree()
        try tree.write(".claude/commands/ship.md", "# Ship it\n", under: tree.project)
        try tree.skill(".claude/skills/swiftui-pro", name: "swiftui-pro", description: "Review SwiftUI", under: tree.project)

        let found = tree.discover()
        let ship = try #require(found.first { $0.name == "ship" })
        #expect(ship.scope == .project)
        #expect(ship.badge == "project")
        #expect(found.first { $0.name == "swiftui-pro" }?.scope == .project)
        // Nothing else earns a badge: a plugin says which plugin it is in its own name.
        #expect(found.first { $0.scope == .user }?.badge == nil)
    }

    @Test("this repository's copy of a name wins over the user's")
    func projectBeatsUser() throws {
        let tree = try Tree()
        try tree.write(".claude/commands/review.md", "---\ndescription: Mine\n---\n")
        try tree.write(".claude/commands/review.md", "---\ndescription: This repository's\n---\n", under: tree.project)

        #expect(tree.discover().first { $0.name == "review" }?.detail == "This repository's")
    }

    // MARK: - Plugins

    /// An installed plugin at a version directory, the way the real cache lays one out.
    private func installPlugin(
        _ tree: Tree,
        name: String,
        version: String,
        commands: [String: String] = [:],
        skills: [String: String] = [:]
    ) throws -> String {
        let root = "\(tree.home)/.claude/plugins/cache/\(name)/\(version)"
        try tree.write(
            "\(root)/.claude-plugin/plugin.json",
            #"{"name": "\#(name)", "version": "\#(version)"}"#,
            under: "/"
        )
        for (file, description) in commands {
            try tree.write("\(root)/commands/\(file).md", "---\ndescription: \(description)\n---\n", under: "/")
        }
        for (folder, description) in skills {
            try tree.write(
                "\(root)/skills/\(folder)/SKILL.md",
                "---\nname: \(folder)\ndescription: \(description)\n---\n",
                under: "/"
            )
        }
        return root
    }

    private func writePluginConfig(
        _ tree: Tree,
        enabled: [String: Bool],
        installed: [String: String]
    ) throws {
        let enabledJSON = try String(
            data: JSONSerialization.data(withJSONObject: ["enabledPlugins": enabled]),
            encoding: .utf8
        ) ?? "{}"
        try tree.write(".claude/settings.json", enabledJSON)

        var plugins: [String: Any] = [:]
        for (key, path) in installed {
            plugins[key] = [["scope": "user", "installPath": path]]
        }
        let installedJSON = try String(
            data: JSONSerialization.data(withJSONObject: ["version": 2, "plugins": plugins]),
            encoding: .utf8
        ) ?? "{}"
        try tree.write(".claude/plugins/installed_plugins.json", installedJSON)
    }

    @Test("an enabled plugin's skills are offered under its own name")
    func pluginSkills() throws {
        let tree = try Tree()
        let root = try installPlugin(
            tree,
            name: "superpowers",
            version: "6.3.0",
            skills: ["requesting-code-review": "Ask for a review before merging"]
        )
        try writePluginConfig(
            tree,
            enabled: ["superpowers@official": true],
            installed: ["superpowers@official": root]
        )

        let found = try #require(tree.discover().first { $0.name == "superpowers:requesting-code-review" })
        #expect(found.detail == "Ask for a review before merging")
        #expect(found.scope == .plugin("superpowers"))
    }

    @Test("a plugin that is installed but switched off is not offered")
    func disabledPluginsAreSkipped() throws {
        let tree = try Tree()
        let root = try installPlugin(
            tree,
            name: "stripe",
            version: "0.6.1",
            commands: ["test-cards": "Card numbers to test with"]
        )
        try writePluginConfig(
            tree,
            enabled: ["stripe@official": false],
            installed: ["stripe@official": root]
        )

        #expect(!tree.names().contains("stripe:test-cards"))
    }

    @Test("only the installed version of a plugin is read, not every copy in the cache")
    func staleVersionsAreSkipped() throws {
        let tree = try Tree()
        _ = try installPlugin(
            tree,
            name: "stripe",
            version: "0.4.5",
            commands: ["old-command": "Long gone"]
        )
        let live = try installPlugin(
            tree,
            name: "stripe",
            version: "0.6.1",
            commands: ["test-cards": "Card numbers to test with"]
        )
        try writePluginConfig(
            tree,
            enabled: ["stripe@official": true],
            installed: ["stripe@official": live]
        )

        let names = tree.names()
        #expect(names.contains("stripe:test-cards"))
        // The cache keeps every version it ever fetched. Walking it blind would offer seven copies.
        #expect(!names.contains("stripe:old-command"))
    }

    @Test("a plugin this repository switches off is not offered here")
    func projectSettingsCanDisableAPlugin() throws {
        let tree = try Tree()
        let root = try installPlugin(
            tree,
            name: "laravel",
            version: "1.0.0",
            skills: ["starter-kit-upgrade": "Pull upstream changes in"]
        )
        try writePluginConfig(
            tree,
            enabled: ["laravel@laravel": true],
            installed: ["laravel@laravel": root]
        )
        #expect(tree.names().contains("laravel:starter-kit-upgrade"))

        try tree.write(
            ".claude/settings.local.json",
            #"{"enabledPlugins": {"laravel@laravel": false}}"#,
            under: tree.project
        )
        #expect(!tree.names().contains("laravel:starter-kit-upgrade"))
    }

    @Test("a plugin that is enabled but not installed anywhere is skipped rather than guessed at")
    func enabledButMissingPlugin() throws {
        let tree = try Tree()
        try tree.write(".claude/settings.json", #"{"enabledPlugins": {"ghost@nowhere": true}}"#)

        #expect(tree.discover().filter { $0.name.hasPrefix("ghost:") }.isEmpty)
    }

    // MARK: - Descriptions

    @Test("a description is read from frontmatter, and a folded one is joined up")
    func foldedDescriptions() throws {
        let tree = try Tree()
        try tree.write(
            ".claude/commands/folded.md",
            "---\ndescription: >\n  Two lines in the file\n  and one line in the menu\n---\n\nbody\n"
        )

        #expect(
            tree.discover().first { $0.name == "folded" }?.detail
                == "Two lines in the file and one line in the menu"
        )
    }

    @Test("a command with no frontmatter is described by its first line")
    func headingAsDescription() throws {
        let tree = try Tree()
        try tree.write(".claude/commands/plain.md", "\n# Do the thing\n\nmore\n")

        #expect(tree.discover().first { $0.name == "plain" }?.detail == "Do the thing")
    }

    @Test("a very long description is cut to one line's worth")
    func longDescriptionsAreTruncated() throws {
        let tree = try Tree()
        let long = String(repeating: "word ", count: 100)
        try tree.write(".claude/commands/long.md", "---\ndescription: \(long)\n---\n")

        let detail = try #require(tree.discover().first { $0.name == "long" }?.detail)
        #expect(detail.count <= SlashCommandIndex.detailLimit)
        #expect(detail.hasSuffix("\u{2026}"))
    }

    @Test("a skill names itself from its frontmatter, and falls back to its folder")
    func skillNaming() throws {
        let tree = try Tree()
        try tree.skill(".claude/skills/folder-name", name: "declared-name", description: "x")
        try tree.write(".claude/skills/no-name/SKILL.md", "---\ndescription: y\n---\n")

        let names = tree.names()
        #expect(names.contains("declared-name"))
        #expect(!names.contains("folder-name"))
        #expect(names.contains("no-name"))
    }

    @Test("a name that could not be typed after a slash is dropped rather than offered")
    func unusableNamesAreDropped() throws {
        let tree = try Tree()
        try tree.write(".claude/commands/has space.md", "# nope\n")
        try tree.skill(".claude/skills/spaced", name: "two words", description: "x")

        let names = tree.names()
        #expect(!names.contains("has space"))
        // The frontmatter name was unusable, so the folder name stands in.
        #expect(names.contains("spaced"))
    }

    // MARK: - What is never read

    @Test("nothing outside a commands or skills tree is opened", .tags(.security))
    func credentialsAreNotRead() throws {
        let tree = try Tree()
        // The real files at these paths hold a live OAuth token. Nothing the menu shows may come
        // from either of them, so a fixture with an unmistakable string in it is planted and the
        // whole catalogue is checked for the string.
        try tree.write(".claude.json", #"{"oauthAccount": {"emailAddress": "SECRET-TOKEN-VALUE"}}"#)
        try tree.write(".claude/.credentials.json", #"{"token": "SECRET-TOKEN-VALUE"}"#)
        try tree.write(".claude/commands/.hidden.md", "---\ndescription: SECRET-TOKEN-VALUE\n---\n")
        try tree.write(".claude/commands/real.md", "---\ndescription: Fine\n---\n")

        let found = tree.discover()
        #expect(found.contains { $0.name == "real" })
        for command in found {
            #expect(!command.name.contains("SECRET-TOKEN-VALUE"))
            #expect(!command.detail.contains("SECRET-TOKEN-VALUE"))
            #expect(!command.name.contains("credentials"))
        }
    }

    @Test("a command carries the file it came from, and a built in carries none")
    func commandsCarryTheirFile() throws {
        let tree = try Tree()
        try tree.write(".claude/commands/commit.md", "# Commit\n")
        try tree.skill(".claude/skills/flare", name: "flare", description: "Manage Flare")

        let found = tree.discover()
        let commit = try #require(found.first { $0.name == "commit" })
        let flare = try #require(found.first { $0.name == "flare" })
        #expect(commit.path == "\(tree.home)/.claude/commands/commit.md")
        #expect(flare.path == "\(tree.home)/.claude/skills/flare/SKILL.md")
        #expect(found.filter { $0.scope == .builtIn && $0.path != nil }.isEmpty)
    }

    // MARK: - What the hover card reads

    @Test("the card reads the prose and not the frontmatter it repeats")
    func documentationStripsFrontmatter() throws {
        let tree = try Tree()
        let path = try tree.write(
            ".claude/skills/flare/SKILL.md",
            """
            ---
            name: flare
            description: A description long enough to fill a card on its own
            ---

            # Flare

            Run `flare errors` to list them.
            """
        )

        let found = try #require(SlashCommandIndex.documentation(of: path, lines: 24, columns: 160))
        #expect(found.lines == ["# Flare", "", "Run `flare errors` to list them."])
        #expect(!found.truncated)
    }

    @Test("a long skill is cut to what a card can hold, in both directions")
    func documentationIsCapped() throws {
        let tree = try Tree()
        let long = String(repeating: "x", count: 400)
        let path = try tree.write(
            ".claude/skills/big/SKILL.md",
            "---\nname: big\n---\n\n" + long + "\n" + (1...40).map { "line \($0)" }.joined(separator: "\n")
        )

        let found = try #require(SlashCommandIndex.documentation(of: path, lines: 24, columns: 160))
        #expect(found.lines.count == 24)
        #expect(found.truncated)
        #expect(found.lines[0].count == 161)
        #expect(found.lines[0].hasSuffix("\u{2026}"))
    }

    @Test("a file that is nothing but frontmatter has nothing to show")
    func documentationOfAnEmptyBody() throws {
        let tree = try Tree()
        let path = try tree.write(".claude/skills/bare/SKILL.md", "---\nname: bare\ndescription: x\n---\n\n")

        #expect(SlashCommandIndex.documentation(of: path, lines: 24, columns: 160) == nil)
    }

    @Test("a command with no file cannot be read, and says so by returning nothing")
    func documentationOfAMissingFile() {
        #expect(SlashCommandIndex.documentation(of: "/nowhere/SKILL.md", lines: 24, columns: 160) == nil)
    }

    @Test("the built in list only holds things a Bloom turn can actually carry out")
    func builtInsAreDeliberate() {
        let names = Set(SlashCommandIndex.builtIns.map(\.name))
        #expect(names.contains("review"))
        #expect(names.contains("security-review"))
        // Terminal interface commands would be offers that go nowhere.
        #expect(!names.contains("vim"))
        #expect(!names.contains("terminal-setup"))
        #expect(!names.contains("statusline"))
        #expect(SlashCommandIndex.builtIns.filter { $0.detail.isEmpty }.isEmpty)
    }

    // MARK: - Ranking

    /// The nine rows Conductor offered for `/revi` on the machine this was written for, minus the
    /// two that are only in the CLI's binary.
    private var conductorsList: [SlashCommand] {
        [
            SlashCommand(name: "review", detail: "", kind: .command, scope: .builtIn),
            SlashCommand(name: "review-pr", detail: "", kind: .skill, scope: .user),
            SlashCommand(name: "review-code", detail: "", kind: .skill, scope: .user),
            SlashCommand(name: "code-review", detail: "", kind: .skill, scope: .builtIn),
            SlashCommand(name: "security-review", detail: "", kind: .command, scope: .builtIn),
            SlashCommand(name: "superpowers:receiving-code-review", detail: "", kind: .skill, scope: .plugin("superpowers")),
            SlashCommand(name: "superpowers:requesting-code-review", detail: "", kind: .skill, scope: .plugin("superpowers")),
            SlashCommand(name: "superpowers:verification-before-completion", detail: "", kind: .skill, scope: .plugin("superpowers")),
            SlashCommand(name: "commit", detail: "", kind: .command, scope: .user),
        ]
    }

    @Test("/revi puts review first and still offers the ones it is only inside")
    func reviRanking() {
        let names = SlashCommand.rank(conductorsList, query: "revi").map(\.command.name)

        #expect(names.first == "review")
        #expect(names.contains("code-review"))
        #expect(names.contains("security-review"))
        #expect(names.contains("review-pr"))
        #expect(names.contains("review-code"))
        // Prefix matching would have stopped at the first two.
        #expect(names.count >= 5)
        #expect(!names.contains("commit"))
    }

    @Test("a bare name outranks the same name with more on the end")
    func shorterWins() {
        let names = SlashCommand.rank(conductorsList, query: "review").map(\.command.name)

        #expect(names.first == "review")
        #expect(names.firstIndex(of: "review-pr")! < names.firstIndex(of: "security-review")!)
    }

    @Test("a namespaced command is found by the part after the colon")
    func namespacedByLeaf() {
        let names = SlashCommand.rank(conductorsList, query: "requesting").map(\.command.name)

        #expect(names.first == "superpowers:requesting-code-review")
        #expect(!names.contains("superpowers:receiving-code-review"))
    }

    @Test("a namespaced command is also found by its plugin")
    func namespacedByPlugin() {
        let names = SlashCommand.rank(conductorsList, query: "superpowers").map(\.command.name)

        #expect(names.count == 3)
        #expect(names.filter { !$0.hasPrefix("superpowers:") }.isEmpty)
    }

    @Test("an empty query offers everything, in the order it was given")
    func emptyQueryOffersEverything() {
        let matches = SlashCommand.rank(conductorsList, query: "")

        #expect(matches.count == conductorsList.count)
        #expect(matches.filter { !$0.highlights.isEmpty }.isEmpty)
    }

    @Test("nothing at all still means nothing at all")
    func nonsenseMatchesNothing() {
        #expect(SlashCommand.rank(conductorsList, query: "zzqx").isEmpty)
    }

    // MARK: - The matcher itself

    @Test("the cheap pass and the thorough one agree about what matches at all")
    func bothPassesAgreeOnMatching() {
        let candidates = [
            "Sources/BloomCore/Store.swift",
            "security-review",
            "superpowers:requesting-code-review",
            "commit",
        ]
        for candidate in candidates {
            for query in ["revi", "store", "sw", "zzz", "commit"] {
                #expect((FuzzyMatch.score(candidate, query: query) != nil)
                    == (FuzzyMatch.hit(candidate, query: query) != nil))
            }
        }
    }

    @Test("the thorough pass never scores a candidate lower than the cheap one")
    func thoroughNeverLoses() {
        for query in ["revi", "review", "cr", "code"] {
            for candidate in ["security-review", "code-review", "review", "superpowers:receiving-code-review"] {
                guard let cheap = FuzzyMatch.score(candidate, query: query) else { continue }
                let thorough = FuzzyMatch.hit(candidate, query: query)
                #expect((thorough?.score ?? Int.min) >= cheap)
            }
        }
    }

    @Test("an empty query matches everything and highlights nothing")
    func emptyQueryMatchesEverything() throws {
        let hit = try #require(FuzzyMatch.hit("review", query: ""))
        #expect(hit.score == 0)
        #expect(hit.positions.isEmpty)
    }

    @Test("a query longer than the candidate cannot match")
    func longQueriesCannotMatch() {
        #expect(FuzzyMatch.hit("ui", query: "uiuiui") == nil)
    }

    // MARK: - Highlighting

    @Test("the row is told the run that matched, not the first letters it could reach")
    func highlightsPointAtTheRun() throws {
        let match = try #require(
            SlashCommand.rank(conductorsList, query: "revi").first { $0.command.name == "security-review" }
        )

        let name = Array(match.command.name)
        let matched = String(match.highlights.map { name[$0] })
        #expect(matched == "revi")
        // "secu(r)ity" is where a single greedy pass would have landed.
        #expect(match.highlights.first == 9)
    }

    @Test("every reported offset is inside the name")
    func highlightsAreInBounds() {
        for match in SlashCommand.rank(conductorsList, query: "rev") {
            let count = match.command.name.count
            #expect(match.highlights.filter { $0 < 0 || $0 >= count }.isEmpty)
            #expect(match.highlights == match.highlights.sorted())
        }
    }
}

/// What the index finds on the machine the suite is running on.
///
/// Off by default and asserted on nothing specific, because the answer changes whenever a plugin
/// updates. It exists so the discovery rules can be checked against a real `~/.claude` rather than
/// only against fixtures, which is where every one of the layout surprises came from: the skills
/// directory being a symlink, the plugin cache holding seven versions of the same plugin, and a
/// plugin naming itself something other than its settings key.
///
///     BLOOM_LOCAL_SKILLS=1 BLOOM_LOCAL_PROJECT=$PWD ./Tools/test-core.sh LocalSlashCommandTests
@Suite("Local slash commands", .enabled(if: ProcessInfo.processInfo.environment["BLOOM_LOCAL_SKILLS"] == "1"))
struct LocalSlashCommandTests {
    @Test("this machine's own commands, skills and plugins are found")
    func theRealTree() {
        // The suite runs from a mirrored package, so the checkout to look at has to be named.
        let project = ProcessInfo.processInfo.environment["BLOOM_LOCAL_PROJECT"]
            ?? FileManager.default.currentDirectoryPath
        let found = SlashCommandIndex.discover(home: NSHomeDirectory(), project: project)

        for command in found {
            print("/\(command.name)  \(command.detail)")
        }
        print("---- \(found.count) entries")

        #expect(found.count > SlashCommandIndex.builtIns.count)
        #expect(found.filter { SlashCommandIndex.sanitised($0.name) == nil }.isEmpty)
        // Nothing may be offered twice: the name is what gets typed.
        #expect(Set(found.map(\.name)).count == found.count)
    }
}

/// Splitting a draft into the chip the composer draws and the prompt written after it.
///
/// The literal text is what the CLI is handed, so the round trip is the whole contract here: a
/// draft that goes through the split and comes back changed is a prompt that runs the wrong
/// command, or none.
@Suite("Slash command draft")
struct SlashCommandDraftTests {
    /// Everything the split is ever asked about, each with what it should come back as.
    static let drafts: [(draft: String, name: String?, body: String)] = [
        ("", nil, ""),
        ("just a prompt", nil, "just a prompt"),
        ("/review ", "review", ""),
        ("/review the diff", "review", "the diff"),
        ("/superpowers:requesting-code-review ", "superpowers:requesting-code-review", ""),
        ("/superpowers:requesting-code-review now please", "superpowers:requesting-code-review", "now please"),
        ("/review-pr #421", "review-pr", "#421"),
        // Still being typed, so still text: the menu is open on it and there is no chip yet.
        ("/revi", nil, "/revi"),
        ("/review", nil, "/review"),
        // A path is not a command. Its first token ends at a slash, not at a space.
        ("/Users/freek/notes.md is the file", nil, "/Users/freek/notes.md is the file"),
        ("/usr/bin/env python", nil, "/usr/bin/env python"),
        ("/", nil, "/"),
        ("/ leading slash", nil, "/ leading slash"),
        // Only a leading command counts. One in the middle of a sentence is a sentence.
        ("please /review this", nil, "please /review this"),
        // Two spaces: the second belongs to the prompt, and has to come back.
        ("/review  double", "review", " double"),
        ("/review\nnewline", nil, "/review\nnewline"),
    ]

    @Test("a draft splits into the command it leads with and everything after it")
    func splitting() {
        for expected in Self.drafts {
            let draft = SlashCommandDraft.parse(expected.draft)
            #expect(draft.name == expected.name, "\(expected.draft)")
            #expect(draft.body == expected.body, "\(expected.draft)")
        }
    }

    @Test("every draft survives the round trip byte for byte")
    func roundTrip() {
        for expected in Self.drafts {
            #expect(SlashCommandDraft.parse(expected.draft).text == expected.draft)
        }
    }

    @Test("editing the prompt leaves the command exactly as it was")
    func editingTheBody() {
        var draft = SlashCommandDraft.parse("/superpowers:requesting-code-review ")
        draft.body = "and be quick about it"

        #expect(draft.text == "/superpowers:requesting-code-review and be quick about it")
        #expect(SlashCommandDraft.parse(draft.text) == draft)
    }

    @Test("picking a command writes a draft that reads back as that command")
    func pickingWritesAChip() {
        for name in ["review", "review-pr", "superpowers:requesting-code-review", "code_review.v2"] {
            let picked = SlashCommandDraft(name: name, body: "")
            #expect(SlashCommandDraft.parse(picked.text).name == name)
        }
    }

    @Test("taking the chip off leaves the prompt untouched")
    func removing() {
        let draft = SlashCommandDraft.parse("/review the diff please")

        #expect(draft.removingCommand().text == "the diff please")
        #expect(draft.removingCommand().name == nil)
    }

    @Test("backspace on a chip with nothing after it puts the text back, ready to edit")
    func backspaceOnALoneChip() throws {
        let draft = SlashCommandDraft.parse("/review ")
        let after = try #require(draft.backspacingCommand())

        #expect(after.text == "/review")
        #expect(after.name == nil)
        // The caret lands at the end, so the next press eats a letter and the menu is open again.
        #expect(draft.caretAfterBackspace == 7)
        #expect(ComposerMenuQuery.slashQuery(in: after.text) == "review")
    }

    @Test("backspace on a chip with a prompt after it removes the chip and keeps the prompt")
    func backspaceWithAPromptAfterIt() throws {
        let draft = SlashCommandDraft.parse("/review the diff")
        let after = try #require(draft.backspacingCommand())

        // Putting the name back would join it to the first word and mangle both.
        #expect(after.text == "the diff")
        #expect(draft.caretAfterBackspace == 0)
    }

    @Test("backspace with no chip is not the composer's business")
    func backspaceWithoutAChip() {
        #expect(SlashCommandDraft.parse("just a prompt").backspacingCommand() == nil)
        #expect(SlashCommandDraft.parse("/revi").backspacingCommand() == nil)
    }

    @Test("every name the index will offer is a name the split recognises")
    func theIndexAndTheSplitAgree() {
        let names = [
            "review", "review-pr", "code_review", "superpowers:requesting-code-review",
            "git:commit", "modernize-assess", "v2.1",
        ]
        for name in names {
            #expect(SlashCommandIndex.sanitised(name) != nil, "\(name)")
            #expect(SlashCommandDraft.parse("/\(name) ").name == name, "\(name)")
        }
    }
}

/// The slash token rule, copied out of the composer so the draft tests can hold it to the same
/// answer. `ComposerMenu` lives in the app target and the core suite cannot see it.
private enum ComposerMenuQuery {
    static func slashQuery(in draft: String) -> String? {
        guard draft.hasPrefix("/") else { return nil }
        let rest = draft.dropFirst()
        guard !rest.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) else { return nil }
        return String(rest)
    }
}
