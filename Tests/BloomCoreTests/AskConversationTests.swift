import Testing
import Foundation
@testable import BloomCore

/// The four decisions behind the chat that belongs to no workspace, three of which are values and
/// are therefore worth pinning here rather than in prose.
@Suite("Ask Bloom's conversation", .tags(.persistence), .scratchDirectory)
struct AskConversationTests {
    /// The permission decision, not the tidiness one. Bloom's default mode is `acceptEdits`, and a
    /// chat started in the owner's home directory under it would accept an edit anywhere in that
    /// directory without asking. An empty directory of its own makes every filesystem reach a
    /// reach outside the working directory, which is a reach that asks.
    @Test("it runs in its own directory beside the database, and not in a home directory")
    func directoryIsBesideTheDatabase() {
        let directory = AskConversation.directory(besideDatabaseAt: "/tmp/somewhere/bloom.sqlite")
        #expect(directory == "/tmp/somewhere/Ask")
        #expect(!directory.hasSuffix("bloom.sqlite"))
    }

    /// Beside the database rather than at a fixed path, so the separation between Bloom and Bloom
    /// Dev that every other piece of per-instance state has costs nothing here. Two copies with
    /// two databases get two directories without a second rule to keep in step.
    @Test("two copies of Bloom get two directories")
    func devCopyIsSeparate() {
        let owner = AskConversation.directory(besideDatabaseAt: "/tmp/Bloom/bloom.sqlite")
        let dev = AskConversation.directory(besideDatabaseAt: "/tmp/Bloom Dev/bloom.sqlite")
        #expect(owner != dev)
    }

    @Test("the directory is made, and is empty")
    func directoryIsMadeEmpty() throws {
        let database = TestScratch.unique("ask-cwd") + "/bloom.sqlite"
        try FileManager.default.createDirectory(
            atPath: (database as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )

        let path = try #require(AskConversation.prepareDirectory(besideDatabaseAt: database))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: path).isEmpty)

        // Made once: a second call over an existing directory answers with it rather than failing.
        #expect(AskConversation.prepareDirectory(besideDatabaseAt: database) == path)
    }

    /// It opens on Ask, and the thing it is not opening on is Full access.
    @Test("a new chat has no workspace and opens on Ask")
    func newSessionOpensOnAsk() {
        let session = AskConversation.newSession()
        #expect(session.workspaceID == nil)
        #expect(session.permissionMode == .auto)
        #expect(session.permissionMode != AppDefaults.fallbackPermissionMode)
        #expect(session.title == AskConversation.title)
        #expect(session.state == .idle)
    }

    /// The row was created on `.auto` and the composer settles a new chat's defaults the first
    /// time it is opened, so without this the mode would have been overwritten before the first
    /// turn with whatever the Models tab holds. The default is `bypassPermissions`, so the chat
    /// that sits above every project would have opened on Full access.
    @Test("the owner's default permission mode does not land on a chat with no worktree")
    func defaultsDoNotOverruleTheMode() {
        var defaults = AppDefaults()
        defaults.permissionMode = .bypassPermissions
        defaults.planMode = false

        let inWorktree = ComposerDefaults.resolve(repo: RepoSettings(), app: defaults)
        #expect(inWorktree.permissionMode == .bypassPermissions)

        let ask = ComposerDefaults.resolve(repo: RepoSettings(), app: defaults, hasWorktree: false)
        #expect(ask.permissionMode == AskConversation.permissionMode)
        // And only the mode. What a conversation costs is the same question here as anywhere.
        #expect(ask.model == inWorktree.model)
        #expect(ask.effort == inWorktree.effort)
    }

    /// Plan mode is the more specific instruction and beats the picker in a worktree. It does not
    /// beat this, because this is not a preference being overruled: it is the one mode that is
    /// true of a conversation with nothing to edit.
    @Test("start in plan mode does not reach it either")
    func planModeDoesNotOverruleTheMode() {
        var defaults = AppDefaults()
        defaults.planMode = true

        #expect(ComposerDefaults.resolve(repo: RepoSettings(), app: defaults).permissionMode == .plan)
        #expect(
            ComposerDefaults.resolve(repo: RepoSettings(), app: defaults, hasWorktree: false)
                .permissionMode == AskConversation.permissionMode
        )
    }

    /// The empty state is the first thing the owner sees, and the surprising half is the second
    /// sentence: it looks exactly like every other conversation in Bloom and it cannot change a
    /// file.
    @Test("the opening words say what it cannot do as well as what it can")
    func openingWordsSayBothHalves() {
        #expect(!AskConversation.emptyHeading.isEmpty)
        #expect(AskConversation.emptyDetail.contains("cannot"))
        #expect(!AskConversation.placeholder.isEmpty)
    }
}
