import Testing
import Foundation
@testable import BloomCore

/// A committed settings file arrives by `git pull`, so whatever is wrong in it is somebody else's
/// mistake. These pin the three promises the loader makes about one: a bad entry never costs its
/// neighbours, never stops the file from loading, and is always said out loud.
@Suite("Settings entries", .scratchDirectory)
struct SettingsEntriesTests {
    private func makeRepo(_ files: [String: String] = [:]) throws -> String {
        let root = TestScratch.unique("bloom-entries")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for (relative, contents) in files {
            let full = (root as NSString).appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                atPath: (full as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try contents.write(toFile: full, atomically: true, encoding: .utf8)
        }
        return root
    }

    /// Only what the repository's own files said. `load` also reads the machine-wide files, and
    /// this Mac's are nothing a test may depend on.
    private func issues(_ settings: RepoSettings, in repo: String) -> [SettingsIssue] {
        settings.issues.filter { $0.path.hasPrefix(repo) }
    }

    private func path(_ repo: String, _ relative: String) -> String {
        (repo as NSString).appendingPathComponent(relative)
    }

    // MARK: - Run scripts

    @Test("a valid file gives every run script with its icon and autostart, in file order")
    func validRunScripts() throws {
        let repo = try makeRepo([
            ".bloom/settings.toml": """
            [scripts.run.vite]
            name = "Vite"
            command = "yarn dev"
            icon = "bolt"
            autostart = true

            [scripts.run.seed]
            name = "Seed Database"
            command = "php artisan migrate:fresh --seed"

            [scripts.run.horizon]
            command = "php artisan horizon"
            """,
        ])
        let settings = SettingsLoader.load(repo: repo)

        #expect(settings.runScripts == [
            RunScript(id: "vite", name: "Vite", command: "yarn dev", icon: "bolt", autostart: true),
            RunScript(id: "seed", name: "Seed Database", command: "php artisan migrate:fresh --seed"),
            RunScript(id: "horizon", name: "Horizon", command: "php artisan horizon"),
        ])
        #expect(issues(settings, in: repo).isEmpty)
        #expect(settings.origins[.runScripts] == path(repo, ".bloom/settings.toml"))
    }

    @Test("the older forms of a run script still read exactly as they did")
    func legacyForms() throws {
        let single = try makeRepo([".bloom/settings.toml": "[scripts]\nrun = \"make serve\"\n"])
        #expect(SettingsLoader.load(repo: single).runScripts == [
            RunScript(id: "run", name: "Run", command: "make serve"),
        ])

        let dotted = try makeRepo([
            ".bloom/settings.toml": "[scripts.run]\ndev = \"bun dev\"\ntest = { command = \"bun test\" }\n",
        ])
        #expect(SettingsLoader.load(repo: dotted).runScripts == [
            RunScript(id: "dev", name: "Dev", command: "bun dev"),
            RunScript(id: "test", name: "Test", command: "bun test"),
        ])

        let fromFile = try makeRepo([
            ".bloom/settings.toml": "[scripts.run.dev]\nfile = \".bloom/run-dev.sh\"\n",
            ".bloom/run-dev.sh": "#!/bin/zsh\nbun dev\n",
        ])
        let loaded = SettingsLoader.load(repo: fromFile)
        #expect(loaded.runScripts.map(\.command) == ["#!/bin/zsh\nbun dev\n"])
        #expect(loaded.scriptFiles[.run("dev")] == ScriptFile(path: ".bloom/run-dev.sh", isMissing: false))
    }

    @Test("no settings file at all, or one with only the file forms of setup and archive, is unchanged")
    func absentAndScriptFilesOnly() throws {
        let empty = try makeRepo()
        let none = SettingsLoader.load(repo: empty)
        #expect(issues(none, in: empty).isEmpty)
        #expect(none.quickPrompts.isEmpty)

        let repo = try makeRepo([
            ".bloom/settings.toml": "[scripts]\nsetup_file = \".bloom/setup.sh\"\narchive_file = \".bloom/archive.sh\"\n",
            ".bloom/setup.sh": "#!/bin/zsh\npnpm install\n",
            ".bloom/archive.sh": "#!/bin/zsh\ndocker compose down\n",
        ])
        let settings = SettingsLoader.load(repo: repo)
        #expect(settings.setupScript == "#!/bin/zsh\npnpm install\n")
        #expect(settings.archiveScript == "#!/bin/zsh\ndocker compose down\n")
        #expect(settings.scriptFiles[.setup] == ScriptFile(path: ".bloom/setup.sh", isMissing: false))
        #expect(settings.quickPrompts.isEmpty)
        #expect(issues(settings, in: repo).isEmpty)
    }

    @Test("a file that will not parse is skipped with an issue naming its line, and the others still load")
    func malformedFile() throws {
        let repo = try makeRepo([
            ".conductor/settings.toml": "[scripts]\nsetup = \"pnpm install\"\n",
            ".bloom/settings.toml": "[scripts]\nsetup = \"bun install\"\nrun = \"unterminated\n",
        ])
        let settings = SettingsLoader.load(repo: repo)

        #expect(settings.setupScript == "pnpm install")
        #expect(!settings.sources.contains(path(repo, ".bloom/settings.toml")))
        let found = issues(settings, in: repo)
        #expect(found.count == 1)
        #expect(found.first?.path == path(repo, ".bloom/settings.toml"))
        #expect(found.first?.entry == .file)
        #expect(found.first?.line == 3)
        #expect(found.first?.message.hasPrefix("This file was skipped: line 3") == true)
    }

    @Test("bad run scripts are skipped one by one, the good ones kept, and each says why")
    func partiallyMalformedRunScripts() throws {
        let repo = try makeRepo([
            ".bloom/settings.toml": """
            [scripts.run.good]
            command = "bun dev"

            [scripts.run.empty]
            name = "Nothing"

            [scripts.run.eager]
            command = "bun test"
            autostart = "yes"

            [scripts.run.pictured]
            command = "bun lint"
            icon = 3

            [scripts.run.numbered]
            command = "bun build"
            name = 1

            [scripts.run.after]
            command = "bun storybook"
            """,
        ])
        let settings = SettingsLoader.load(repo: repo)

        #expect(settings.runScripts.map(\.id) == ["good", "after"])
        let found = issues(settings, in: repo)
        #expect(found.map(\.entry) == [
            .runScript("empty"), .runScript("eager"), .runScript("pictured"), .runScript("numbered"),
        ])
        #expect(found.map(\.message) == [
            "Run script \u{201C}empty\u{201D} was skipped: it has no command.",
            "Run script \u{201C}eager\u{201D} was skipped: autostart has to be true or false.",
            "Run script \u{201C}pictured\u{201D} was skipped: icon has to be text in quotes.",
            "Run script \u{201C}numbered\u{201D} was skipped: name has to be text in quotes.",
        ])
        #expect(found.map(\.line) == [4, 7, 11, 15])
    }

    @Test("a second run script with the same name is skipped, whatever its case or spacing")
    func duplicateRunScriptNames() throws {
        let repo = try makeRepo([
            ".bloom/settings.toml": """
            [scripts.run.vite]
            name = "Vite"
            command = "yarn dev"

            [scripts.run.other]
            name = "  vite "
            command = "pnpm dev"

            [scripts.run.Vite]
            command = "npm run dev"
            """,
        ])
        let settings = SettingsLoader.load(repo: repo)

        #expect(settings.runScripts.map(\.id) == ["vite"])
        #expect(issues(settings, in: repo).map(\.entry) == [.runScript("other"), .runScript("Vite")])
    }

    @Test("a run script whose file is missing is kept, and says it cannot run")
    func missingRunScriptFile() throws {
        let repo = try makeRepo([".bloom/settings.toml": "[scripts.run.dev]\nfile = \".bloom/gone.sh\"\n"])
        let settings = SettingsLoader.load(repo: repo)

        #expect(settings.runScripts.map(\.id) == ["dev"])
        #expect(settings.scriptFiles[.run("dev")]?.isMissing == true)
        #expect(issues(settings, in: repo).map(\.message) == [
            "Run script \u{201C}dev\u{201D} cannot run: .bloom/gone.sh does not exist.",
        ])
    }

    @Test("keys this build does not know are ignored without a word")
    func unknownKeysAreIgnored() throws {
        let repo = try makeRepo([
            ".bloom/settings.toml": """
            "$schema" = "https://conductor.build/schemas/settings.repo.schema.json"
            future_feature = { enabled = true }

            [scripts.run.dev]
            command = "bun dev"
            colour = "orange"

            [[quick_prompts]]
            name = "Review"
            prompt = "Review the diff."
            priority = 3
            """,
        ])
        let settings = SettingsLoader.load(repo: repo)

        #expect(settings.runScripts.map(\.id) == ["dev"])
        #expect(settings.quickPrompts.map(\.name) == ["Review"])
        #expect(issues(settings, in: repo).isEmpty)
    }

    @Test("run scripts come out in the order the file states them, not sorted")
    func fileOrderIsKept() throws {
        let repo = try makeRepo([
            ".bloom/settings.toml": """
            [scripts.run.zebra]
            command = "z"

            [scripts.run.apple]
            command = "a"

            [scripts.run]
            mango = "m"
            """,
        ])
        #expect(SettingsLoader.load(repo: repo).runScripts.map(\.id) == ["zebra", "apple", "mango"])
    }

    // MARK: - Quick prompts

    @Test("project quick prompts are read with their defaults")
    func validQuickPrompts() throws {
        let repo = try makeRepo([
            ".bloom/settings.toml": #"""
            [[quick_prompts]]
            name = "Check for N+1 queries"
            prompt = """
            Look through the controllers for N+1 queries.
            """
            symbol = "terminal"

            [[quick_prompts]]
            name = "Write the changelog"
            prompt = "Write a changelog entry."
            new_chat = true
            """#,
        ])
        let settings = SettingsLoader.load(repo: repo)

        #expect(settings.quickPrompts == [
            ProjectQuickPrompt(
                name: "Check for N+1 queries", text: "Look through the controllers for N+1 queries.\n",
                symbol: "terminal", source: path(repo, ".bloom/settings.toml")
            ),
            ProjectQuickPrompt(
                name: "Write the changelog", text: "Write a changelog entry.",
                opensNewChat: true, source: path(repo, ".bloom/settings.toml")
            ),
        ])
        #expect(settings.quickPrompts.map(\.id) == ["check for n+1 queries", "write the changelog"])
        #expect(issues(settings, in: repo).isEmpty)
    }

    @Test("bad quick prompts are skipped one by one, and send_immediately is refused but the prompt kept")
    func partiallyMalformedQuickPrompts() throws {
        let repo = try makeRepo([
            ".bloom/settings.toml": """
            [[quick_prompts]]
            prompt = "No name here."

            [[quick_prompts]]
            name = "Empty"

            [[quick_prompts]]
            name = "Typed"
            prompt = "Words."
            new_chat = "yes"

            [[quick_prompts]]
            name = "Hasty"
            prompt = "Ship it."
            send_immediately = true

            [[quick_prompts]]
            name = "hasty"
            prompt = "Again."

            [[quick_prompts]]
            name = "Fine"
            prompt = "Fine words."
            symbol = 7
            """,
        ])
        let settings = SettingsLoader.load(repo: repo)

        #expect(settings.quickPrompts.map(\.name) == ["Hasty"])
        let found = issues(settings, in: repo)
        #expect(found.map(\.entry) == [
            .quickPrompt(index: 0, name: nil),
            .quickPrompt(index: 1, name: "Empty"),
            .quickPrompt(index: 2, name: "Typed"),
            .quickPrompt(index: 3, name: "Hasty"),
            .quickPrompt(index: 4, name: "hasty"),
            .quickPrompt(index: 5, name: "Fine"),
        ])
        #expect(found.map(\.message) == [
            "Quick prompt 1 was skipped: it has no name.",
            "Quick prompt \u{201C}Empty\u{201D} was skipped: it has no prompt.",
            "Quick prompt \u{201C}Typed\u{201D} was skipped: new_chat has to be true or false.",
            "Quick prompt \u{201C}Hasty\u{201D} will not send on its own: send_immediately is not supported in a shared settings file.",
            "Quick prompt \u{201C}hasty\u{201D} was skipped: another quick prompt already has that name.",
            "Quick prompt \u{201C}Fine\u{201D} was skipped: symbol has to be text in quotes.",
        ])
        #expect(found.first?.line == 1)
    }

    @Test("an unknown symbol falls back to the default, and says so, while one emoji is kept")
    func unknownSymbolFallsBack() throws {
        let repo = try makeRepo([
            ".bloom/settings.toml": "[[quick_prompts]]\nname = \"A\"\nprompt = \"B\"\nsymbol = \"not.a.symbol\"\n",
        ])
        let settings = SettingsLoader.load(repo: repo)
        #expect(settings.quickPrompts.first?.symbol == QuickPrompt.defaultSymbol)
        #expect(issues(settings, in: repo).map(\.message) == [
            "Quick prompt \u{201C}A\u{201D} shows the default symbol: \u{201C}not.a.symbol\u{201D} is not one Bloom offers.",
        ])

        let emoji = try makeRepo([
            ".bloom/settings.toml": "[[quick_prompts]]\nname = \"A\"\nprompt = \"B\"\nsymbol = \"\u{1F680}\"\n",
        ])
        let withEmoji = SettingsLoader.load(repo: emoji)
        #expect(withEmoji.quickPrompts.first?.symbol == "\u{1F680}")
        #expect(issues(withEmoji, in: emoji).isEmpty)
    }

    @Test("the last repository file that states quick prompts replaces the list, including with none")
    func quickPromptLayering() throws {
        let shared = "[[quick_prompts]]\nname = \"Team\"\nprompt = \"Team words.\"\n"
        let layered = try makeRepo([
            ".conductor/settings.toml": shared,
            ".bloom/settings.toml": "[[quick_prompts]]\nname = \"Bloom\"\nprompt = \"Bloom words.\"\n",
            ".bloom/settings.local.toml": "[git]\nbranch_prefix = \"freek\"\n",
        ])
        #expect(SettingsLoader.load(repo: layered).quickPrompts.map(\.name) == ["Bloom"])

        let cleared = try makeRepo([
            ".bloom/settings.toml": shared,
            ".bloom/settings.local.toml": "quick_prompts = []\n",
        ])
        #expect(SettingsLoader.load(repo: cleared).quickPrompts.isEmpty)
    }

    @Test("quick prompts are never read from a machine-wide file")
    func homeFilesStateNoQuickPrompts() throws {
        var settings = RepoSettings()
        let toml = try TOML.parse("[[quick_prompts]]\nname = \"Mine\"\nprompt = \"Words.\"\n")
        // `apply` is what `load` runs for a machine-wide file; quick prompts are a second step
        // only the repository's files get.
        SettingsLoader.apply(toml, from: "/home/.bloom/settings.toml", to: &settings)
        #expect(settings.quickPrompts.isEmpty)
    }
}
