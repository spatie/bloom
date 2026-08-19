import Testing
import Foundation
@testable import BloomCore

/// A setup script is a program. It has a shebang, it wants `shellcheck`, and somebody will want to
/// run it straight from a terminal while they are writing it, so it lives in a file of its own and
/// the settings file points at it.
///
/// These pin the part of that which writes into somebody's repository: which form is read, when a
/// string becomes a file, where that file lands, what mode it gets, and what happens when the file
/// the settings name is not there.
@Suite("Scripts as files", .scratchDirectory)
struct ScriptFileTests {
    private func makeRepo(_ files: [String: String] = [:]) throws -> String {
        let root = TestScratch.unique("bloom-scripts")
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

    private func mode(_ repo: String, _ relative: String) throws -> Int? {
        let full = (repo as NSString).appendingPathComponent(relative)
        let attributes = try FileManager.default.attributesOfItem(atPath: full)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }

    // MARK: - Reading

    @Test("a named file is read as the script")
    func aNamedFileIsRead() throws {
        let repo = try makeRepo([
            ".bloom/settings.toml": "[scripts]\nsetup_file = \".bloom/setup.sh\"\n",
            ".bloom/setup.sh": "#!/bin/zsh\nbun install\n",
        ])

        let settings = SettingsLoader.load(repo: repo)

        #expect(settings.setupScript == "#!/bin/zsh\nbun install\n")
        #expect(settings.scriptFiles[.setup]?.path == ".bloom/setup.sh")
        #expect(settings.scriptFiles[.setup]?.isMissing == false)
    }

    @Test("a script embedded by Conductor is still read")
    func anInlineScriptIsStillRead() throws {
        let repo = try makeRepo([
            ".conductor/settings.toml": "[scripts]\nsetup = \"bun install\"\n",
        ])

        let settings = SettingsLoader.load(repo: repo)

        #expect(settings.setupScript == "bun install")
        // No file, so nothing claims there is one. That is what tells the rest of the app this
        // script is a string and what makes the window offer to move it.
        #expect(settings.scriptFiles[.setup] == nil)
    }

    @Test("inside one file the named file wins over an embedded string")
    func theFileWinsWithinAFile() throws {
        let repo = try makeRepo([
            ".bloom/settings.toml": """
            [scripts]
            setup = "the old string"
            setup_file = ".bloom/setup.sh"
            """,
            ".bloom/setup.sh": "#!/bin/zsh\nthe file\n",
        ])

        #expect(SettingsLoader.load(repo: repo).setupScript == "#!/bin/zsh\nthe file\n")
    }

    @Test("a file named in .bloom overrides a string Conductor embedded")
    func bloomOutranksConductorAcrossForms() throws {
        let repo = try makeRepo([
            ".conductor/settings.toml": "[scripts]\nsetup = \"the conductor string\"\n",
            ".bloom/settings.toml": "[scripts]\nsetup_file = \".bloom/setup.sh\"\n",
            ".bloom/setup.sh": "#!/bin/zsh\nthe bloom file\n",
        ])

        #expect(SettingsLoader.load(repo: repo).setupScript == "#!/bin/zsh\nthe bloom file\n")
    }

    @Test("a run script can name a file too")
    func aRunScriptCanNameAFile() throws {
        let repo = try makeRepo([
            ".bloom/settings.toml": """
            [scripts.run.dev]
            file = ".bloom/run-dev.sh"
            """,
            ".bloom/run-dev.sh": "#!/bin/zsh\nbun dev\n",
        ])

        let settings = SettingsLoader.load(repo: repo)

        #expect(settings.runScripts.map(\.id) == ["dev"])
        #expect(settings.runScripts.first?.command == "#!/bin/zsh\nbun dev\n")
        #expect(settings.scriptFiles[.run("dev")]?.isMissing == false)
    }

    // MARK: - Promotion

    @Test("a script with a shebang is written out as a file, and the settings point at it")
    func aProgramBecomesAFile() throws {
        let repo = try makeRepo()
        let script = "#!/bin/zsh\nset -euo pipefail\nbun install\n"

        try SettingsWriter.write([.setupScript(script)], repo: repo, settings: RepoSettings())

        #expect(read(repo, ".bloom/setup.sh") == script)
        let settings = read(repo, ".bloom/settings.toml") ?? ""
        #expect(settings.contains("setup_file = \".bloom/setup.sh\""))
        // Both forms present would be a file stating the same script twice, with the reader's
        // preference deciding which won.
        #expect(!settings.contains("\nsetup ="))
    }

    @Test("the file Bloom writes can actually be run")
    func theFileIsExecutable() throws {
        let repo = try makeRepo()
        try SettingsWriter.write(
            [.setupScript("#!/bin/zsh\nbun install")], repo: repo, settings: RepoSettings()
        )

        #expect(try mode(repo, ".bloom/setup.sh") == 0o755)
    }

    @Test("a script written without a closing newline gets one")
    func aScriptEndsWithANewline() throws {
        let repo = try makeRepo()
        try SettingsWriter.write(
            [.setupScript("#!/bin/zsh\nbun install")], repo: repo, settings: RepoSettings()
        )

        #expect(read(repo, ".bloom/setup.sh") == "#!/bin/zsh\nbun install\n")
    }

    @Test("one command stays a string, where it reads best")
    func oneLineStaysInline() throws {
        let repo = try makeRepo()
        try SettingsWriter.write([.setupScript("bun install")], repo: repo, settings: RepoSettings())

        #expect(read(repo, ".bloom/setup.sh") == nil)
        #expect(read(repo, ".bloom/settings.toml")?.contains("setup = \"bun install\"") == true)
    }

    @Test("a string Conductor embedded is moved to a file the first time it is edited")
    func anInlineConductorScriptIsPromoted() throws {
        let conductor = "[scripts]\nsetup = \"bun install\"\n"
        let repo = try makeRepo([".conductor/settings.toml": conductor])
        let settings = SettingsLoader.load(repo: repo)

        try SettingsWriter.write(
            [.setupScript("#!/bin/zsh\nbun install\nbun run build\n")], repo: repo, settings: settings
        )

        #expect(read(repo, ".bloom/setup.sh")?.hasPrefix("#!/bin/zsh") == true)
        #expect(read(repo, ".bloom/settings.toml")?.contains("setup_file") == true)
        // Read the old thing, write the new thing. Conductor's file is left exactly as the team
        // committed it, and Conductor goes on reading it.
        #expect(read(repo, ".conductor/settings.toml") == conductor)
        #expect(SettingsLoader.load(repo: repo).setupScript == "#!/bin/zsh\nbun install\nbun run build\n")
    }

    @Test("a string Bloom itself wrote earlier is moved to a file, not left behind")
    func anInlineBloomScriptIsMigrated() throws {
        let script = "#!/bin/zsh\nbun install\n"
        let repo = try makeRepo([
            ".bloom/settings.toml": "[scripts]\nsetup = \"\"\"\n#!/bin/zsh\nbun install\n\"\"\"\n",
        ])
        let settings = SettingsLoader.load(repo: repo)
        #expect(settings.setupScript?.contains("bun install") == true)

        try SettingsWriter.write([.setupScript(script + "bun run build\n")], repo: repo, settings: settings)

        let written = read(repo, ".bloom/settings.toml") ?? ""
        #expect(written.contains("setup_file = \".bloom/setup.sh\""))
        #expect(!written.contains("bun install"))
        #expect(read(repo, ".bloom/setup.sh")?.contains("bun run build") == true)
    }

    @Test("a path somebody chose by hand is kept rather than repointed at Bloom's own name")
    func aStatedPathIsKept() throws {
        let repo = try makeRepo([
            ".bloom/settings.toml": "[scripts]\nsetup_file = \"bin/dev-setup.sh\"\n",
            "bin/dev-setup.sh": "#!/bin/zsh\nold\n",
        ])
        let settings = SettingsLoader.load(repo: repo)

        try SettingsWriter.write([.setupScript("#!/bin/zsh\nnew\n")], repo: repo, settings: settings)

        #expect(read(repo, "bin/dev-setup.sh") == "#!/bin/zsh\nnew\n")
        #expect(read(repo, ".bloom/setup.sh") == nil)
        #expect(read(repo, ".bloom/settings.toml")?.contains("bin/dev-setup.sh") == true)
    }

    @Test("a personal script does not overwrite the one the team shares")
    func aLocalScriptGetsItsOwnFile() throws {
        let repo = try makeRepo([
            ".bloom/settings.local.toml": "[scripts]\nsetup = \"mine\"\n",
        ])
        let settings = SettingsLoader.load(repo: repo)

        try SettingsWriter.write(
            [.setupScript("#!/bin/zsh\nmine, longer\n")], repo: repo, settings: settings
        )

        #expect(read(repo, ".bloom/setup.local.sh")?.contains("mine, longer") == true)
        #expect(read(repo, ".bloom/setup.sh") == nil)
        #expect(read(repo, ".bloom/settings.local.toml")?.contains("setup.local.sh") == true)
    }

    @Test("the ignore rule keeps a personal script out of git and the shared one in")
    func theIgnoreRuleCoversScripts() throws {
        let repo = try makeRepo()
        try SettingsWriter.write(
            [.setupScript("#!/bin/zsh\nbun install\n")], repo: repo, settings: RepoSettings()
        )

        let ignore = read(repo, ".bloom/.gitignore") ?? ""
        #expect(ignore.contains("*.local.sh"))
        #expect(!ignore.contains("\nsetup.sh"))
    }

    @Test("a run script long enough to be a program gets a file of its own")
    func aLongRunScriptBecomesAFile() throws {
        let repo = try makeRepo()
        let scripts = [
            RunScript(id: "dev", name: "Dev", command: "bun dev"),
            RunScript(id: "test", name: "Test", command: "#!/bin/zsh\nbun test --watch\n"),
        ]

        try SettingsWriter.write([.runScripts(scripts)], repo: repo, settings: RepoSettings())

        let settings = read(repo, ".bloom/settings.toml") ?? ""
        #expect(settings.contains("command = \"bun dev\""))
        #expect(settings.contains("file = \".bloom/run-test.sh\""))
        #expect(read(repo, ".bloom/run-test.sh")?.contains("bun test --watch") == true)
        #expect(read(repo, ".bloom/run-dev.sh") == nil)
    }

    @Test("what the writer writes is what the loader reads back")
    func roundTripsThroughTheLoader() throws {
        let repo = try makeRepo()
        let setup = "#!/bin/zsh\nset -euo pipefail\ncp .env.example .env\nbun install\n"

        try SettingsWriter.write(
            [.setupScript(setup), .archiveScript("#!/bin/zsh\ndocker compose down\n")],
            repo: repo, settings: RepoSettings()
        )

        let settings = SettingsLoader.load(repo: repo)
        #expect(settings.setupScript == setup)
        #expect(settings.archiveScript == "#!/bin/zsh\ndocker compose down\n")
        #expect(settings.scriptFiles[.setup]?.path == ".bloom/setup.sh")
        #expect(settings.scriptFiles[.archive]?.path == ".bloom/archive.sh")
    }

    @Test("clearing a script takes the pointer out and leaves the file where it is")
    func clearingRemovesThePointer() throws {
        let repo = try makeRepo()
        try SettingsWriter.write(
            [.setupScript("#!/bin/zsh\nbun install\n")], repo: repo, settings: RepoSettings()
        )
        let settings = SettingsLoader.load(repo: repo)

        try SettingsWriter.write([.setupScript(nil)], repo: repo, settings: settings)

        #expect(read(repo, ".bloom/settings.toml")?.contains("setup_file") == false)
        #expect(SettingsLoader.load(repo: repo).setupScript == nil)
        // Not deleted. It may have been committed, and it may have been edited by hand.
        #expect(read(repo, ".bloom/setup.sh")?.contains("bun install") == true)
    }

    // MARK: - A file that is not there

    @Test("a settings file naming a script that is not there says so rather than pretending")
    func aMissingFileIsReported() throws {
        let repo = try makeRepo([
            ".bloom/settings.toml": "[scripts]\nsetup_file = \".bloom/setup.sh\"\n",
        ])

        let settings = SettingsLoader.load(repo: repo)

        #expect(settings.setupScript == nil)
        #expect(settings.scriptFiles[.setup]?.path == ".bloom/setup.sh")
        #expect(settings.scriptFiles[.setup]?.isMissing == true)
        // The origin is still recorded, so the window can name the file and an edit knows where to
        // go: a broken pointer is repaired by writing the file it points at.
        #expect(settings.origins[.setupScript] != nil)
    }

    @Test("a missing file is written again at the path the settings already name")
    func aMissingFileIsRepairedInPlace() throws {
        let repo = try makeRepo([
            ".bloom/settings.toml": "[scripts]\nsetup_file = \"bin/dev-setup.sh\"\n",
        ])
        let settings = SettingsLoader.load(repo: repo)

        try SettingsWriter.write([.setupScript("#!/bin/zsh\nback\n")], repo: repo, settings: settings)

        #expect(read(repo, "bin/dev-setup.sh") == "#!/bin/zsh\nback\n")
        #expect(try mode(repo, "bin/dev-setup.sh") == 0o755)
    }

    // MARK: - Starting one

    @Test("a file with a shebang, marked executable, is run as itself")
    func anExecutableFileIsRunDirectly() throws {
        let repo = try makeRepo()
        try SettingsWriter.write(
            [.setupScript("#!/bin/zsh\nbun install\n")], repo: repo, settings: RepoSettings()
        )
        let settings = SettingsLoader.load(repo: repo)

        let launch = ScriptLaunch.resolve(
            text: settings.setupScript, file: settings.scriptFiles[.setup], repo: repo
        )

        #expect(launch == .executable(path: (repo as NSString).appendingPathComponent(".bloom/setup.sh")))
        #expect(launch?.arguments == [])
    }

    @Test("a file with no shebang cannot introduce itself, so its text is run as before")
    func aFileWithoutAShebangIsSourced() throws {
        let repo = try makeRepo([
            ".bloom/settings.toml": "[scripts]\nsetup_file = \".bloom/setup.sh\"\n",
            ".bloom/setup.sh": "bun install\n",
        ])
        let settings = SettingsLoader.load(repo: repo)

        let launch = ScriptLaunch.resolve(
            text: settings.setupScript, file: settings.scriptFiles[.setup], repo: repo
        )

        #expect(launch == .source("bun install\n"))
        #expect(launch?.executable == "/bin/zsh")
    }

    @Test("a file whose executable bit was lost still runs")
    func aFileWithoutTheBitIsSourced() throws {
        let repo = try makeRepo([
            ".bloom/settings.toml": "[scripts]\nsetup_file = \".bloom/setup.sh\"\n",
            ".bloom/setup.sh": "#!/bin/zsh\nbun install\n",
        ])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: (repo as NSString).appendingPathComponent(".bloom/setup.sh")
        )
        let settings = SettingsLoader.load(repo: repo)

        let launch = ScriptLaunch.resolve(
            text: settings.setupScript, file: settings.scriptFiles[.setup], repo: repo
        )

        #expect(launch == .source("#!/bin/zsh\nbun install\n"))
    }

    @Test("a script embedded in the settings file runs the way it always did")
    func anInlineScriptIsSourced() throws {
        let repo = try makeRepo([".bloom/settings.toml": "[scripts]\nsetup = \"bun install\"\n"])
        let settings = SettingsLoader.load(repo: repo)

        let launch = ScriptLaunch.resolve(
            text: settings.setupScript, file: settings.scriptFiles[.setup], repo: repo
        )

        #expect(launch == .source("bun install"))
        #expect(launch?.arguments == ["-c", "bun install"])
    }

    @Test("a named file that is not there is a broken pointer, not an absent script")
    func aMissingFileIsItsOwnAnswer() throws {
        let repo = try makeRepo([
            ".bloom/settings.toml": "[scripts]\nsetup_file = \".bloom/setup.sh\"\n",
        ])
        let settings = SettingsLoader.load(repo: repo)

        let launch = ScriptLaunch.resolve(
            text: settings.setupScript, file: settings.scriptFiles[.setup], repo: repo
        )

        #expect(launch == .missing(path: ".bloom/setup.sh"))
        // Whatever a caller does with it, it never runs the path as a command by accident.
        #expect(launch?.executable == "/bin/zsh")
        #expect(launch?.arguments == ["-c", "true"])
    }

    @Test("no script at all is no launch at all")
    func noScriptIsNoLaunch() throws {
        let repo = try makeRepo()
        let settings = SettingsLoader.load(repo: repo)

        #expect(ScriptLaunch.resolve(
            text: settings.setupScript, file: settings.scriptFiles[.setup], repo: repo
        ) == nil)
    }
}
