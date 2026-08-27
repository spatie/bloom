import Testing
import Foundation
@testable import BloomCore

/// What a session nobody has configured is allowed to do.
///
/// The default moved from Accept edits to Full access, and the reason it needs a suite of its own
/// is that "the default" is not one value in one place: the create window, the composer's first
/// open, a `bloom://` link and a session row written with no mode stated each used to reach their
/// own literal. They all reach `AppDefaults.fallbackPermissionMode` now, and these tests are what
/// stops a second literal growing back.
///
/// The last two say out loud what the default actually grants on each backend, because a constant
/// naming a mode is not a description of what that mode permits, and this is the one change in
/// Bloom where the difference is the whole point.
@Suite("The default permission mode")
struct PermissionDefaultTests {
    @Test("a brand new session may act without asking")
    func fallbackIsFullAccess() {
        #expect(AppDefaults.fallbackPermissionMode == .bypassPermissions)
        #expect(PermissionMode.bypassPermissions.label(on: .codex) == "Full access")
    }

    /// The three values that stand in for "nobody has said anything yet", which must agree. Each
    /// of them was `.acceptEdits` spelled out separately before.
    @Test("every unstated starting point agrees with the fallback")
    func nothingRestatesTheDefault() {
        #expect(AppDefaults().permissionMode == .bypassPermissions)
        #expect(ComposerControls().permissionMode == .bypassPermissions)
        #expect(Session(workspaceID: WorkspaceID("w")).permissionMode == .bypassPermissions)
    }

    @Test("a store with nothing in it hands back full access")
    func emptyStoreLoadsTheFallback() async throws {
        let store = try makeTestStore("permission-default-empty")

        #expect(await AppDefaults.load(from: store).permissionMode == .bypassPermissions)
    }

    /// The fallback is a fallback. This is the half of the change that is easy to miss: a copy of
    /// Bloom whose Settings, Models tab has ever been saved holds a row for this key, and that row
    /// keeps winning. Moving the built-in reaches a fresh database and nothing else.
    @Test("a mode chosen in Settings still beats the built-in")
    func theStoredChoiceWins() async throws {
        let store = try makeTestStore("permission-default-stored")
        try await store.setSetting(AppDefaults.Key.permissionMode, PermissionMode.auto.rawValue)

        let defaults = await AppDefaults.load(from: store)
        #expect(defaults.permissionMode == .auto)
        #expect(ComposerDefaults.resolve(repo: RepoSettings(), app: defaults).permissionMode == .auto)
    }

    /// "Start in plan mode" is the more specific instruction of the two and was already documented
    /// as beating the permission picker. It has to beat the new default as well, or the toggle
    /// would read as broken for anybody who has it on.
    @Test("plan mode still outranks it")
    func planModeStillWins() {
        var defaults = AppDefaults()
        defaults.planMode = true

        #expect(ComposerDefaults.resolve(repo: RepoSettings(), app: defaults).permissionMode == .plan)
    }

    @Test("a repository file has no say over it, so the default reaches an unconfigured repo")
    func aRepoFileCannotChangeIt() {
        let resolved = ComposerDefaults.resolve(repo: RepoSettings(), app: AppDefaults())

        #expect(resolved.permissionMode == .bypassPermissions)
    }

    /// **The one deliberate exception, named here so it does not read as the drift this suite
    /// exists to stop.** Every unstated starting point above agrees with the fallback. Ask Bloom's
    /// does not, and it is not an unstated starting point: it is a chat with no worktree, where
    /// Full access would mean the whole machine rather than a copy of a project. See
    /// `AskConversation.permissionMode`, and `modeOnOpening` for why it has to be reapplied.
    @Test("the chat with no worktree is the one thing that does not take the default")
    func theConversationWithNoWorktreeIsTheException() {
        #expect(AskConversation.permissionMode != AppDefaults.fallbackPermissionMode)
        #expect(AskConversation.newSession().permissionMode == .auto)
        #expect(
            ComposerDefaults
                .resolve(repo: RepoSettings(), app: AppDefaults(), hasWorktree: false)
                .permissionMode == AskConversation.permissionMode
        )
    }

    /// What Claude Code is told. `--permission-mode bypassPermissions` skips the permission
    /// prompt for tool calls; it is not a sandbox, so the CLI's own hooks and settings files are
    /// still what they were.
    @Test("on Claude Code it is the flag that stops the asking")
    func reachesClaudeCodeAsBypass() {
        #expect(AppDefaults.fallbackPermissionMode.cliValue == "bypassPermissions")
    }

    /// What Codex is told, which is a different shape: an approval policy crossed with a sandbox
    /// rather than a mode. Full access is the only mode that turns the sandbox off, so
    /// a Codex chat on the default may write outside its own worktree, which the Accept edits it
    /// replaces could not.
    @Test("on Codex it is no approvals and no sandbox")
    func reachesCodexAsDangerFullAccess() {
        let mode = AppDefaults.fallbackPermissionMode
        #expect(CodexRunner.approvalPolicy(for: mode) == .never)
        #expect(CodexRunner.sandboxMode(for: mode) == .dangerFullAccess)
        #expect(CodexRunner.sandboxPolicy(for: mode, writableRoot: "/tmp/w")
            == .object(["type": .string("dangerFullAccess")]))
    }
}
