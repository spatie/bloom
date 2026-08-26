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

    /// Without this the lock holds exactly once. `ComposerDefaults.resolve` settles a chat's mode
    /// the first time it is opened and never again, and the picker writes the owner's choice onto
    /// the row, so a Full access chosen once to get something done would have been what this
    /// conversation opened on for ever after.
    @Test("the mode goes back to Ask on the next launch, and not before")
    func theModeIsReappliedEachLaunch() {
        // What the owner left it on, a launch later.
        #expect(
            AskConversation.modeOnOpening(stored: .bypassPermissions, isFirstOpenSinceLaunch: true)
                == AskConversation.permissionMode
        )

        // The same choice, still in the launch it was made in. Overruling it while somebody is
        // watching would be a picker that does not work.
        #expect(
            AskConversation.modeOnOpening(stored: .bypassPermissions, isFirstOpenSinceLaunch: false)
                == nil
        )

        // Nothing to do, so nothing is written: this is a column with two writers.
        #expect(
            AskConversation.modeOnOpening(
                stored: AskConversation.permissionMode, isFirstOpenSinceLaunch: true
            ) == nil
        )
    }

    /// The choice expires, so the menu has to say so before it is made rather than after.
    @Test("the permission menu says what a mode means with no worktree")
    func theMenuSaysWhatAModeMeansHere() {
        let inWorktree = ComposerControls(
            session: Session(workspaceID: WorkspaceID("w1")), isFastMode: false, outputStyle: ""
        )
        #expect(inWorktree.hasWorktree)
        #expect(inWorktree.missingPermissionModeNote == nil)

        let ask = ComposerControls(
            session: AskConversation.newSession(), isFastMode: false, outputStyle: ""
        )
        #expect(!ask.hasWorktree)
        let note = ask.missingPermissionModeNote ?? ""
        #expect(note.contains("whole machine"))
        #expect(note.contains("Bloom next starts"))
    }

    /// The empty state is the first thing the owner sees, and it used to open by listing what this
    /// chat cannot do, in Bloom's own vocabulary ("this chat has no worktree"). It says what to ask
    /// for now. The limits are still said, in the permission menu, which is where they change a
    /// decision rather than merely being true.
    @Test("the opening words offer something rather than apologise")
    func openingWordsOffer() {
        #expect(!AskConversation.emptyHeading.isEmpty)
        #expect(!AskConversation.placeholder.isEmpty)
        #expect(!AskConversation.emptyDetail.contains("cannot"))
        // "worktree" is a word for a thing the reader meets later, if at all.
        #expect(!AskConversation.emptyDetail.lowercased().contains("worktree"))
        #expect(!AskConversation.emptyHeading.lowercased().contains("worktree"))
    }
}
