import Testing
import Foundation
@testable import BloomCore

/// The settings screen has two things it must never do: put a value somewhere the user cannot
/// find it, and overwrite a value a teammate committed with one that only this machine can see.
/// Both come down to which file an edit lands in, so that is what these pin.
@Suite("Settings writer", .scratchDirectory)
struct SettingsWriterTests {
    private func makeRepo(_ files: [String: String] = [:]) throws -> String {
        let root = TestScratch.unique("bloom-writer")
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

    /// TOML's multi-line forms keep the newline before their closing delimiter, so prose comes
    /// back one newline longer than it went in. That is the same slack `RepoSettingsDraft` gives
    /// every value it compares.
    private func trimmed(_ text: String?) -> String? {
        text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func read(_ repo: String, _ relative: String) -> String? {
        try? String(contentsOfFile: (repo as NSString).appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - Instructions

    /// The field in the Instructions pane, round tripped. It is prose, and often several
    /// paragraphs of it, so what it comes back as matters: TOML's multi-line forms are the only
    /// ones that survive a newline, and a value that came back mangled would reach an agent.
    @Test("what a project says about merging survives being written and read back")
    func instructionsRoundTrip() throws {
        let repo = try makeRepo()
        let text = "Squash unless the branch is a stack.\n\nNever merge on a Friday."

        try SettingsWriter.write(
            [.mergeInstructions(text), .conflictInstructions("Regenerate the lock file.")],
            repo: repo, settings: RepoSettings()
        )
        let settings = SettingsLoader.load(repo: repo)

        #expect(trimmed(ProjectInstructions.stated(.merge, in: settings)) == text)
        #expect(trimmed(ProjectInstructions.stated(.fixConflicts, in: settings))
            == "Regenerate the lock file.")
    }

    /// Prose stays in the settings file however long it is, where a script of the same length
    /// would have been moved into one of its own. A project that wants a file has the one the
    /// turn already prefers, and two ways to end up with a file would be two files to keep right.
    @Test("instructions are never moved into a file of their own")
    func instructionsStayInTheSettingsFile() throws {
        let repo = try makeRepo()

        try SettingsWriter.write(
            [.mergeInstructions("#!/bin/zsh\nnot a script, but it starts like one")],
            repo: repo, settings: RepoSettings()
        )

        #expect(read(repo, ".bloom/settings.toml")?.contains("not a script") == true)
        #expect(read(repo, ".bloom/merge-instructions.md") == nil)
    }

    /// Clearing the box has to be a statement rather than a deletion when something below is still
    /// saying it, which is the same rule the setup script follows and for the same reason.
    @Test("clearing the box takes the line out")
    func clearingTakesTheLineOut() throws {
        let repo = try makeRepo([".bloom/settings.toml": "[instructions]\nmerge = \"Squash.\"\n"])
        let settings = SettingsLoader.load(repo: repo)

        try SettingsWriter.write([.mergeInstructions(nil)], repo: repo, settings: settings)

        #expect(SettingsLoader.load(repo: repo).mergeInstructions == nil)
        #expect(read(repo, ".bloom/settings.toml")?.contains("merge") == false)
    }

    // MARK: - Destination

    @Test("an edit to a value Bloom's own file states goes back to that file")
    func editsGoBackToTheirOrigin() throws {
        let repo = try makeRepo([
            ".bloom/settings.toml": "[scripts]\nsetup = \"shared\"\n",
            ".bloom/settings.local.toml": "[scripts]\narchive = \"mine\"\n",
        ])
        let settings = SettingsLoader.load(repo: repo)

        #expect(
            SettingsWriter.destination(for: .setupScript, in: settings, repo: repo)
                == (repo as NSString).appendingPathComponent(".bloom/settings.toml")
        )
        #expect(
            SettingsWriter.destination(for: .archiveScript, in: settings, repo: repo)
                == (repo as NSString).appendingPathComponent(".bloom/settings.local.toml")
        )
    }

    @Test("a value read out of .conductor is written to .bloom at the same tier")
    func conductorValuesAreWrittenToBloom() throws {
        let repo = try makeRepo([
            ".conductor/settings.toml": "[scripts]\nsetup = \"shared\"\n",
            ".conductor/settings.local.toml": "[scripts]\narchive = \"mine\"\n",
        ])
        let settings = SettingsLoader.load(repo: repo)

        // Not `.bloom/settings.toml` for both. The shared file ranks below every `.local` one, so
        // an archive script written there would be shadowed by the `.conductor` local file it was
        // meant to replace, and the edit would look like it did nothing.
        #expect(
            SettingsWriter.destination(for: .setupScript, in: settings, repo: repo)
                == (repo as NSString).appendingPathComponent(".bloom/settings.toml")
        )
        #expect(
            SettingsWriter.destination(for: .archiveScript, in: settings, repo: repo)
                == (repo as NSString).appendingPathComponent(".bloom/settings.local.toml")
        )
    }

    @Test("writing to .bloom leaves the .conductor file exactly as the team committed it")
    func conductorFilesAreNeverRewritten() throws {
        let original = "[scripts]\nsetup = \"pnpm install\"\n"
        let repo = try makeRepo([".conductor/settings.toml": original])
        let settings = SettingsLoader.load(repo: repo)

        try SettingsWriter.write([.setupScript("bun install")], repo: repo, settings: settings)

        #expect(read(repo, ".conductor/settings.toml") == original)
        #expect(read(repo, ".bloom/settings.toml")?.contains("bun install") == true)
        // And Bloom's file wins, which is the only reason forking the value is tolerable.
        #expect(SettingsLoader.load(repo: repo).setupScript == "bun install")
    }

    @Test("a script a .conductor file states can still be cleared")
    func clearingOverridesTheFileBelow() throws {
        let repo = try makeRepo([".conductor/settings.toml": "[scripts]\nsetup = \"pnpm install\"\n"])
        let settings = SettingsLoader.load(repo: repo)

        try SettingsWriter.write([.setupScript("")], repo: repo, settings: settings)

        // Removing a line from `.bloom` would have left the `.conductor` one showing through, so
        // the clear is written as a statement instead.
        #expect(read(repo, ".bloom/settings.toml")?.contains("setup = \"\"") == true)
        #expect(SettingsLoader.load(repo: repo).setupScript == nil)
    }

    @Test("a value only a machine-wide file states is not edited there")
    func homeFilesAreNeverRewritten() throws {
        let repo = try makeRepo()
        var settings = RepoSettings()
        settings.origins[.branchPrefix] = "\(NSHomeDirectory())/.bloom/settings.toml"

        // This screen is about one repository. Rewriting the home file from it would change every
        // other repository on the machine, so the edit becomes a repository-level override.
        #expect(
            SettingsWriter.destination(for: .branchPrefix, in: settings, repo: repo)
                == (repo as NSString).appendingPathComponent(".bloom/settings.toml")
        )
    }

    @Test("a setting nobody states yet goes to Bloom's own shared file")
    func defaultFileIsAlwaysBloom() throws {
        let onlyConductor = try makeRepo([".conductor/settings.toml": "[scripts]\nsetup = \"x\"\n"])
        #expect(
            SettingsWriter.defaultFile(repo: onlyConductor)
                == (onlyConductor as NSString).appendingPathComponent(".bloom/settings.toml")
        )

        let bare = try makeRepo()
        #expect(
            SettingsWriter.defaultFile(repo: bare)
                == (bare as NSString).appendingPathComponent(".bloom/settings.toml")
        )
    }

    @Test("the folder Bloom creates keeps the personal file out of git")
    func bloomFolderCarriesItsOwnIgnoreRule() throws {
        let repo = try makeRepo()
        try SettingsWriter.write([.setupScript("bun install")], repo: repo, settings: RepoSettings())

        // `settings.toml` and the scripts beside it are meant to be committed: sharing the setup
        // script is why it lives in the repository at all. The `.local` pair is the opposite, and
        // a personal script is written as `setup.local.sh`, so the rule covers both spellings.
        #expect(read(repo, ".bloom/.gitignore") == "settings.local.toml\n*.local.sh\n")
    }

    @Test("a .gitignore already in the folder is left alone")
    func anExistingIgnoreFileIsNotRewritten() throws {
        let repo = try makeRepo([".bloom/.gitignore": "# mine\n"])
        try SettingsWriter.write([.setupScript("bun install")], repo: repo, settings: RepoSettings())
        #expect(read(repo, ".bloom/.gitignore") == "# mine\n")
    }

    // MARK: - Round trips

    @Test("what the writer writes is what the loader reads back")
    func roundTripsThroughTheLoader() throws {
        let repo = try makeRepo()
        var settings = SettingsLoader.load(repo: repo)

        try SettingsWriter.write(
            [
                .setupScript("set -e\ncomposer install"),
                .filesToCopy([".env*", "certs/*.pem"]),
                .runScripts([
                    RunScript(id: "dev", name: "Dev", command: "bun dev --port $BLOOM_PORT"),
                    RunScript(id: "test", name: "Watch tests", command: "bun test --watch"),
                ]),
                .branchPrefix("freek"),
                .deleteBranchOnArchive(true),
                .runMode("concurrent"),
            ],
            repo: repo,
            settings: settings
        )

        settings = SettingsLoader.load(repo: repo)
        #expect(settings.setupScript?.trimmingCharacters(in: .newlines) == "set -e\ncomposer install")
        #expect(settings.filesToCopy == [".env*", "certs/*.pem"])
        #expect(settings.runScripts.map(\.id) == ["dev", "test"])
        #expect(settings.runScripts.map(\.name) == ["Dev", "Watch tests"])
        #expect(settings.runScripts.first?.command == "bun dev --port $BLOOM_PORT")
        #expect(settings.branchPrefix == "freek")
        #expect(settings.deleteBranchOnArchive)
        #expect(settings.runMode == "concurrent")
    }

    @Test("clearing a value removes the key rather than writing an empty one")
    func clearingRemovesTheKey() throws {
        let repo = try makeRepo([".bloom/settings.toml": "[scripts]\nsetup = \"x\"\narchive = \"y\"\n"])
        let settings = SettingsLoader.load(repo: repo)

        try SettingsWriter.write([.setupScript("")], repo: repo, settings: settings)

        #expect(read(repo, ".bloom/settings.toml")?.contains("setup") == false)
        #expect(read(repo, ".bloom/settings.toml")?.contains("archive") == true)
        #expect(SettingsLoader.load(repo: repo).setupScript == nil)
    }

    @Test("an empty glob list is written, so 'copy nothing' is expressible")
    func emptyGlobListMeansNothing() throws {
        let repo = try makeRepo()
        try SettingsWriter.write([.filesToCopy([])], repo: repo, settings: RepoSettings())
        #expect(SettingsLoader.load(repo: repo).filesToCopy == [])
    }

    @Test("a removed run script takes its table with it")
    func removingARunScriptRemovesItsTable() throws {
        let repo = try makeRepo([
            ".bloom/settings.toml": """
            [scripts.run.dev]
            command = "bun dev"

            [scripts.run.test]
            command = "bun test"
            """,
        ])
        let settings = SettingsLoader.load(repo: repo)
        #expect(settings.runScripts.count == 2)

        try SettingsWriter.write(
            [.runScripts([RunScript(id: "dev", name: "Dev", command: "bun dev")])],
            repo: repo,
            settings: settings
        )

        let after = SettingsLoader.load(repo: repo)
        #expect(after.runScripts.map(\.id) == ["dev"])
        #expect(read(repo, ".bloom/settings.toml")?.contains("scripts.run.test") == false)
    }

    @Test("the legacy single-string run script is replaced, not left to fight the new tables")
    func legacyRunStringIsReplaced() throws {
        let repo = try makeRepo([".bloom/settings.toml": "[scripts]\nrun = \"make serve\"\n"])
        let settings = SettingsLoader.load(repo: repo)
        #expect(settings.runScripts.map(\.command) == ["make serve"])

        try SettingsWriter.write(
            [.runScripts([RunScript(id: "dev", name: "Dev", command: "bun dev")])],
            repo: repo,
            settings: settings
        )

        #expect(read(repo, ".bloom/settings.toml")?.contains("run = ") == false)
        #expect(SettingsLoader.load(repo: repo).runScripts.map(\.command) == ["bun dev"])
    }

    @Test("a teammate's comments and unknown keys survive an edit")
    func aTeamFileSurvives() throws {
        let original = """
        "$schema" = "https://conductor.build/schemas/settings.repo.schema.json"

        # Needed because the CI image has no bun.
        [scripts]
        setup = "pnpm install"

        [scripts.run.dev]
        available_in = [ "local" ]
        command = "pnpm dev"
        icon = "play"
        """
        let repo = try makeRepo([".bloom/settings.toml": original])
        let settings = SettingsLoader.load(repo: repo)

        try SettingsWriter.write([.setupScript("bun install")], repo: repo, settings: settings)

        let after = try #require(read(repo, ".bloom/settings.toml"))
        #expect(after.contains("# Needed because the CI image has no bun."))
        #expect(after.contains("icon = \"play\""))
        #expect(after.contains("available_in = [ \"local\" ]"))
        #expect(after.contains("$schema"))
        #expect(after.contains("setup = \"bun install\""))
    }

    @Test("a change made on disk in the meantime is not clobbered")
    func aConcurrentChangeToAnotherKeySurvives() throws {
        let repo = try makeRepo([".bloom/settings.toml": "[scripts]\nsetup = \"old\"\n"])
        let settings = SettingsLoader.load(repo: repo)

        // Someone edits the file, or `git pull` does, after the window read it.
        try "[scripts]\nsetup = \"old\"\narchive = \"added behind our back\"\n"
            .write(
                toFile: (repo as NSString).appendingPathComponent(".bloom/settings.toml"),
                atomically: true,
                encoding: .utf8
            )

        try SettingsWriter.write([.setupScript("new")], repo: repo, settings: settings)

        let after = SettingsLoader.load(repo: repo)
        #expect(after.setupScript == "new")
        #expect(after.archiveScript == "added behind our back")
    }

    @Test("writing nothing new creates no file")
    func noChangeMeansNoFile() throws {
        let repo = try makeRepo()
        let written = try SettingsWriter.write([.setupScript(nil)], repo: repo, settings: RepoSettings())
        #expect(written.isEmpty)
        #expect(read(repo, ".bloom/settings.toml") == nil)
    }
}
