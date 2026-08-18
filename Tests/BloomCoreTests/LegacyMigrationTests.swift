import Foundation
import Testing
@testable import BloomCore

/// The rename moved both places the user's state lives. Neither move is undoable by hand, so both
/// are pinned here.
@Suite("LegacyDefaults")
struct LegacyDefaultsTests {
    /// Two throwaway domains standing in for `be.spatie.baton` and `be.spatie.bloom`.
    private func domains() -> (old: String, new: String, defaults: UserDefaults) {
        let stamp = UUID().uuidString
        let old = "bloom.test.legacy.\(stamp)"
        let new = "bloom.test.current.\(stamp)"
        return (old, new, UserDefaults(suiteName: new)!)
    }

    private func clean(_ old: String, _ new: String) {
        UserDefaults.standard.removePersistentDomain(forName: old)
        UserDefaults.standard.removePersistentDomain(forName: new)
    }

    @Test("carries the old domain's values across")
    func copiesValues() throws {
        let (old, new, defaults) = domains()
        defer { clean(old, new) }

        let legacy = try #require(UserDefaults(suiteName: old))
        legacy.set(18.0, forKey: "terminal.fontSize")
        legacy.set(true, forKey: "notifications.enabled")
        legacy.set("w-work", forKey: "sidebar.lastWorkspaceID")
        legacy.set(false, forKey: "terminal.ghosttyTheme")

        let outcome = LegacyDefaults.migrate(from: old, into: defaults)

        #expect(outcome.ran)
        #expect(outcome.copied == 4)
        #expect(defaults.double(forKey: "terminal.fontSize") == 18.0)
        #expect(defaults.bool(forKey: "notifications.enabled"))
        #expect(defaults.string(forKey: "sidebar.lastWorkspaceID") == "w-work")
        #expect(defaults.object(forKey: "terminal.ghosttyTheme") as? Bool == false)
    }

    @Test("never overwrites a value already set under the new identifier")
    func keepsNewerValues() throws {
        let (old, new, defaults) = domains()
        defer { clean(old, new) }

        let legacy = try #require(UserDefaults(suiteName: old))
        legacy.set(11.0, forKey: "chat.textSize")
        legacy.set("old", forKey: "prompts.pullRequest")
        defaults.set(20.0, forKey: "chat.textSize")

        let outcome = LegacyDefaults.migrate(from: old, into: defaults)

        #expect(outcome.copied == 1)
        #expect(outcome.skipped == 1)
        #expect(defaults.double(forKey: "chat.textSize") == 20.0)
        #expect(defaults.string(forKey: "prompts.pullRequest") == "old")
    }

    @Test("runs once, so a value changed after it cannot be reverted by a second launch")
    func runsOnce() throws {
        let (old, new, defaults) = domains()
        defer { clean(old, new) }

        let legacy = try #require(UserDefaults(suiteName: old))
        legacy.set(11.0, forKey: "chat.textSize")

        #expect(LegacyDefaults.migrate(from: old, into: defaults).copied == 1)
        defaults.set(20.0, forKey: "chat.textSize")

        let second = LegacyDefaults.migrate(from: old, into: defaults)
        #expect(!second.ran)
        #expect(defaults.double(forKey: "chat.textSize") == 20.0)
    }

    @Test("a fresh install still records that it ran")
    func emptyLegacyDomain() throws {
        let (old, new, defaults) = domains()
        defer { clean(old, new) }

        let outcome = LegacyDefaults.migrate(from: old, into: defaults)
        #expect(outcome.ran)
        #expect(outcome.copied == 0)
        #expect(defaults.bool(forKey: LegacyDefaults.completionKey))
        #expect(!LegacyDefaults.migrate(from: old, into: defaults).ran)
    }

    @Test("the flag itself is not carried across, so the new domain decides for itself")
    func doesNotCopyTheFlag() throws {
        let (old, new, defaults) = domains()
        defer { clean(old, new) }

        let legacy = try #require(UserDefaults(suiteName: old))
        legacy.set(true, forKey: LegacyDefaults.completionKey)
        legacy.set(9.0, forKey: "chat.textSize")

        #expect(LegacyDefaults.migrate(from: old, into: defaults).copied == 1)
        #expect(defaults.double(forKey: "chat.textSize") == 9.0)
    }
}

@Suite("LegacyDatabase", .scratchDirectory)
struct LegacyDatabaseTests {
    private func scratch() -> URL {
        URL(fileURLWithPath: TestScratch.unique("bloom-dbmigrate"))
    }

    private func seed(_ path: URL) async throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let store = try Store(path: path.path)
        let repo = try await store.upsert(Repo(name: "there-there", path: "/tmp/there-there"))
        try await store.upsert(Workspace(
            repoID: repo.id, name: "show me technologies", branch: "freek/show-me",
            path: "/Users/someone/baton/workspaces/there-there/freek-show-me", baseBranch: "main"
        ))
    }

    @Test("copies the old database and hands back the new path")
    func migrates() async throws {
        let root = scratch()
        let legacy = root.appendingPathComponent("Baton/baton.sqlite")
        let destination = root.appendingPathComponent("Bloom/bloom.sqlite")
        try await seed(legacy)

        let outcome = LegacyDatabase.adopt(legacy: legacy, destination: destination)

        #expect(outcome.result == .migrated)
        #expect(outcome.path == destination.path)

        let moved = try Store(path: destination.path)
        #expect(try await moved.repos().map(\.name) == ["there-there"])
        #expect(try await moved.workspaces().map(\.branch) == ["freek/show-me"])
    }

    @Test("leaves the original where it is, so a failed launch still has a database to open")
    func keepsTheOriginal() async throws {
        let root = scratch()
        let legacy = root.appendingPathComponent("Baton/baton.sqlite")
        let destination = root.appendingPathComponent("Bloom/bloom.sqlite")
        try await seed(legacy)

        LegacyDatabase.adopt(legacy: legacy, destination: destination)

        #expect(FileManager.default.fileExists(atPath: legacy.path))
        let original = try Store(path: legacy.path)
        #expect(try await original.repos().count == 1)
    }

    @Test("carries transactions that were still sitting in the write-ahead log")
    func carriesUncheckpointedWrites() async throws {
        let root = scratch()
        let legacy = root.appendingPathComponent("Baton/baton.sqlite")
        let destination = root.appendingPathComponent("Bloom/bloom.sqlite")
        try await seed(legacy)

        // Written through a connection that is still open, which is exactly the state a copy of
        // the `.sqlite` file alone would read as missing rows.
        let live = try Store(path: legacy.path)
        let repo = try await live.upsert(Repo(name: "late", path: "/tmp/late"))
        #expect(FileManager.default.fileExists(atPath: legacy.path + "-wal"))

        LegacyDatabase.adopt(legacy: legacy, destination: destination)

        let moved = try Store(path: destination.path)
        #expect(try await moved.repos().map(\.id).contains(repo.id))
    }

    @Test("a database already at the new path is never copied over")
    func refusesToOverwrite() async throws {
        let root = scratch()
        let legacy = root.appendingPathComponent("Baton/baton.sqlite")
        let destination = root.appendingPathComponent("Bloom/bloom.sqlite")
        try await seed(legacy)

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let current = try Store(path: destination.path)
        try await current.upsert(Repo(name: "since-the-rename", path: "/tmp/since"))

        let outcome = LegacyDatabase.adopt(legacy: legacy, destination: destination)

        #expect(outcome.result == .nothingToDo)
        #expect(outcome.path == destination.path)
        let reopened = try Store(path: destination.path)
        #expect(try await reopened.repos().map(\.name) == ["since-the-rename"])
    }

    @Test("nothing to migrate is not a failure")
    func freshInstall() throws {
        let root = scratch()
        let destination = root.appendingPathComponent("Bloom/bloom.sqlite")

        let outcome = LegacyDatabase.adopt(
            legacy: root.appendingPathComponent("Baton/baton.sqlite"), destination: destination
        )

        #expect(outcome.result == .nothingToDo)
        #expect(outcome.path == destination.path)
    }

    @Test("an unreadable old file leaves the app pointed at it rather than at half a copy")
    func fallsBackToLegacy() throws {
        let root = scratch()
        let legacy = root.appendingPathComponent("Baton/baton.sqlite")
        let destination = root.appendingPathComponent("Bloom/bloom.sqlite")
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("this is not a database".utf8).write(to: legacy)

        let outcome = LegacyDatabase.adopt(legacy: legacy, destination: destination)

        #expect(outcome.result == .keptLegacy)
        #expect(outcome.path == legacy.path)
        #expect(outcome.problem != nil)
        // The half written copy has to be gone, or the next launch would treat it as the real
        // database purely because a file exists at that path.
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }
}
