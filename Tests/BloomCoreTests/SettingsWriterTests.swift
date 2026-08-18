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

    private func read(_ repo: String, _ relative: String) -> String? {
        try? String(contentsOfFile: (repo as NSString).appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - Destination

    @Test("an edit goes back to the file that already states the value")
    func editsGoBackToTheirOrigin() throws {
        let repo = try makeRepo([
            ".conductor/settings.toml": "[scripts]\nsetup = \"shared\"\n",
            ".conductor/settings.local.toml": "[scripts]\narchive = \"mine\"\n",
        ])
        let settings = SettingsLoader.load(repo: repo)

        #expect(
            SettingsWriter.destination(for: .setupScript, in: settings, repo: repo)
                == (repo as NSString).appendingPathComponent(".conductor/settings.toml")
        )
        #expect(
            SettingsWriter.destination(for: .archiveScript, in: settings, repo: repo)
                == (repo as NSString).appendingPathComponent(".conductor/settings.local.toml")
        )
    }

    @Test("a value only a machine-wide file states is not edited there")
    func homeFilesAreNeverRewritten() throws {
        let repo = try makeRepo()
        var settings = RepoSettings()
        settings.origins[.branchPrefix] = "\(NSHomeDirectory())/.conductor/settings.toml"

        // This screen is about one repository. Rewriting the home file from it would change every
        // other repository on the machine, so the edit becomes a repository-level override.
        #expect(
            SettingsWriter.destination(for: .branchPrefix, in: settings, repo: repo)
                == (repo as NSString).appendingPathComponent(".conductor/settings.toml")
        )
    }

    @Test("a setting nobody states yet goes to the repository's existing shared file")
    func defaultFilePrefersWhatIsThere() throws {
        let onlyBloom = try makeRepo([".bloom/settings.toml": "[scripts]\nsetup = \"x\"\n"])
        #expect(
            SettingsWriter.defaultFile(repo: onlyBloom)
                == (onlyBloom as NSString).appendingPathComponent(".bloom/settings.toml")
        )

        let bare = try makeRepo()
        #expect(
            SettingsWriter.defaultFile(repo: bare)
                == (bare as NSString).appendingPathComponent(".conductor/settings.toml")
        )
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
        let repo = try makeRepo([".conductor/settings.toml": "[scripts]\nsetup = \"x\"\narchive = \"y\"\n"])
        let settings = SettingsLoader.load(repo: repo)

        try SettingsWriter.write([.setupScript("")], repo: repo, settings: settings)

        #expect(read(repo, ".conductor/settings.toml")?.contains("setup") == false)
        #expect(read(repo, ".conductor/settings.toml")?.contains("archive") == true)
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
            ".conductor/settings.toml": """
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
        #expect(read(repo, ".conductor/settings.toml")?.contains("scripts.run.test") == false)
    }

    @Test("the legacy single-string run script is replaced, not left to fight the new tables")
    func legacyRunStringIsReplaced() throws {
        let repo = try makeRepo([".conductor/settings.toml": "[scripts]\nrun = \"make serve\"\n"])
        let settings = SettingsLoader.load(repo: repo)
        #expect(settings.runScripts.map(\.command) == ["make serve"])

        try SettingsWriter.write(
            [.runScripts([RunScript(id: "dev", name: "Dev", command: "bun dev")])],
            repo: repo,
            settings: settings
        )

        #expect(read(repo, ".conductor/settings.toml")?.contains("run = ") == false)
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
        let repo = try makeRepo([".conductor/settings.toml": original])
        let settings = SettingsLoader.load(repo: repo)

        try SettingsWriter.write([.setupScript("bun install")], repo: repo, settings: settings)

        let after = try #require(read(repo, ".conductor/settings.toml"))
        #expect(after.contains("# Needed because the CI image has no bun."))
        #expect(after.contains("icon = \"play\""))
        #expect(after.contains("available_in = [ \"local\" ]"))
        #expect(after.contains("$schema"))
        #expect(after.contains("setup = \"bun install\""))
    }

    @Test("a change made on disk in the meantime is not clobbered")
    func aConcurrentChangeToAnotherKeySurvives() throws {
        let repo = try makeRepo([".conductor/settings.toml": "[scripts]\nsetup = \"old\"\n"])
        let settings = SettingsLoader.load(repo: repo)

        // Someone edits the file, or `git pull` does, after the window read it.
        try "[scripts]\nsetup = \"old\"\narchive = \"added behind our back\"\n"
            .write(
                toFile: (repo as NSString).appendingPathComponent(".conductor/settings.toml"),
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
        #expect(read(repo, ".conductor/settings.toml") == nil)
    }
}
