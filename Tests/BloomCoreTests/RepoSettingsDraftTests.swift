import Testing
import Foundation
@testable import BloomCore

/// What pressing Save is about to write, asserted rather than judged from a screenshot.
@Suite("Repository settings draft", .scratchDirectory)
struct RepoSettingsDraftTests {
    @Test("a draft that has not been touched writes nothing")
    func untouchedDraftIsClean() {
        var settings = RepoSettings()
        settings.setupScript = "pnpm install"
        settings.filesToCopy = [".env*"]
        settings.runScripts = [RunScript(id: "dev", name: "Dev", command: "pnpm dev")]

        #expect(RepoSettingsDraft(settings).edits(comparedTo: settings).isEmpty)
    }

    /// TOML's multi-line forms keep the newline before their closing delimiter, so a script comes
    /// back one newline longer than it went in. Without trimming, the window would claim unsaved
    /// changes the moment it reopened, forever.
    @Test("a script that only gained TOML's trailing newline is not a change")
    func trailingNewlineIsNotAChange() {
        var settings = RepoSettings()
        settings.setupScript = "set -e\ncomposer install\n"

        var draft = RepoSettingsDraft(settings)
        draft.setupScript = "set -e\ncomposer install"

        #expect(draft.edits(comparedTo: settings).isEmpty)
    }

    @Test("only the fields that changed are written")
    func onlyChangedFieldsAreWritten() {
        var settings = RepoSettings()
        settings.setupScript = "pnpm install"
        settings.branchPrefix = "freek"

        var draft = RepoSettingsDraft(settings)
        draft.setupScript = "bun install"

        let edits = draft.edits(comparedTo: settings)
        #expect(edits == [.setupScript("bun install")])
    }

    /// Both boxes in the Instructions pane, and the one that was not touched staying out of the
    /// save. A project's settings file is shared, so opening the window and looking at it must not
    /// add a key to it.
    @Test("only the instructions box that changed is written")
    func onlyTheEditedInstructionsAreWritten() {
        var settings = RepoSettings()
        settings.mergeInstructions = "Squash."
        settings.conflictInstructions = "Regenerate the lock file."

        var draft = RepoSettingsDraft(settings)
        draft.mergeInstructions = "Squash unless the branch is a stack."

        #expect(draft.edits(comparedTo: settings)
            == [.mergeInstructions("Squash unless the branch is a stack.")])
    }

    /// Emptying the box is what a project says when it has nothing extra to add after all, and it
    /// has to reach the file rather than being read as "nothing changed".
    @Test("emptying the instructions box is a change")
    func emptyingTheBoxIsAChange() {
        var settings = RepoSettings()
        settings.mergeInstructions = "Squash."

        var draft = RepoSettingsDraft(settings)
        draft.mergeInstructions = "  \n "

        #expect(draft.edits(comparedTo: settings) == [.mergeInstructions("")])
    }

    @Test("clearing the glob field asks for nothing to be copied")
    func clearingGlobsIsAnAnswer() {
        var settings = RepoSettings()
        settings.filesToCopy = [".env*"]

        var draft = RepoSettingsDraft(settings)
        draft.filesToCopyText = "\n  \n"

        #expect(draft.edits(comparedTo: settings) == [.filesToCopy([])])
    }

    @Test("blank lines and stray spaces are not patterns")
    func globParsingIgnoresNoise() {
        var draft = RepoSettingsDraft()
        draft.filesToCopyText = "  .env*  \n\n certs/*.pem\n"
        #expect(draft.globs == [".env*", "certs/*.pem"])
    }

    @Test("a new run script is given a table name taken from what it is called")
    func newRunScriptsAreNamedAfterThemselves() {
        var draft = RepoSettingsDraft()
        draft.runScripts = [
            DraftRunScript(name: "Dev server", command: "bun dev"),
            DraftRunScript(name: "Watch tests", command: "bun test --watch"),
        ]

        #expect(draft.resolvedRunScripts.map(\.id) == ["dev-server", "watch-tests"])
        #expect(draft.resolvedRunScripts.map(\.name) == ["Dev server", "Watch tests"])
    }

    @Test("two scripts called the same thing do not collide")
    func duplicateNamesGetDistinctTables() {
        var draft = RepoSettingsDraft()
        draft.runScripts = [
            DraftRunScript(name: "Run", command: "a"),
            DraftRunScript(name: "Run", command: "b"),
            DraftRunScript(key: "run-2", name: "Existing", command: "c"),
        ]

        let ids = draft.resolvedRunScripts.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("run-2"))
    }

    @Test("a row with no command is one somebody abandoned, and is not written")
    func emptyRunScriptRowsAreDropped() {
        var draft = RepoSettingsDraft()
        draft.runScripts = [
            DraftRunScript(name: "Dev", command: "bun dev"),
            DraftRunScript(name: "", command: "   "),
        ]

        #expect(draft.resolvedRunScripts.map(\.command) == ["bun dev"])
    }

    @Test("renaming a saved script keeps the table it is already stored in")
    func renamingKeepsTheTable() {
        var settings = RepoSettings()
        settings.runScripts = [RunScript(id: "dev", name: "Dev", command: "bun dev")]

        var draft = RepoSettingsDraft(settings)
        draft.runScripts[0].name = "Development server"

        #expect(draft.resolvedRunScripts == [
            RunScript(id: "dev", name: "Development server", command: "bun dev"),
        ])
    }

    /// The end of the pipeline the settings window drives: draft, difference, file, and back.
    @Test("what the window would save is what the loader reads back")
    func draftRoundTripsThroughTheFiles() throws {
        let repo = TestScratch.unique("bloom-draft")
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)

        let settings = SettingsLoader.load(repo: repo)
        var draft = RepoSettingsDraft(settings)
        draft.setupScript = "set -e\nbun install"
        draft.filesToCopyText = ".env*\ncerts/*.pem"
        draft.runScripts = [DraftRunScript(name: "Dev", command: "bun dev")]
        draft.deleteBranchOnArchive = true

        try SettingsWriter.write(draft.edits(comparedTo: settings), repo: repo, settings: settings)

        let reloaded = SettingsLoader.load(repo: repo)
        #expect(reloaded.setupScript?.trimmingCharacters(in: .newlines) == "set -e\nbun install")
        #expect(reloaded.filesToCopy == [".env*", "certs/*.pem"])
        #expect(reloaded.runScripts == [RunScript(id: "dev", name: "Dev", command: "bun dev")])
        #expect(reloaded.deleteBranchOnArchive)

        // And reopening the window on the saved state offers nothing more to save.
        #expect(RepoSettingsDraft(reloaded).edits(comparedTo: reloaded).isEmpty)
    }
}
