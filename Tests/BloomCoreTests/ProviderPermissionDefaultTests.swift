import Testing
@testable import BloomCore

@Suite("Per-provider permission defaults", .scratchDirectory)
struct ProviderPermissionDefaultTests {
    @Test("provider overrides persist independently and clearing one restores the fallback")
    func persistence() async throws {
        let store = try makeTestStore("provider-permissions")
        try await store.setSetting(AppDefaults.Key.permissionMode, PermissionMode.acceptEdits.rawValue)
        let original = await AppDefaults.load(from: store)
        var first = original
        first.setPermissionMode(.auto, for: .claudeCode)
        try await first.saveChanges(from: original, to: store)

        var stale = original
        stale.setPermissionMode(.autoReview, for: .codex)
        try await stale.saveChanges(from: original, to: store)
        let loaded = await AppDefaults.load(from: store)
        #expect(loaded.permissionMode(for: .claudeCode) == .auto)
        #expect(loaded.permissionMode(for: .codex) == .autoReview)
        #expect(loaded.permissionMode(for: .grok) == .acceptEdits)
        #expect(loaded.storedModel == nil)

        var cleared = loaded
        cleared.setPermissionMode(nil, for: .claudeCode)
        try await cleared.saveChanges(from: loaded, to: store)
        let reloaded = await AppDefaults.load(from: store)
        #expect(reloaded.providerPermissionModes[.claudeCode] == nil)
        #expect(reloaded.permissionMode(for: .claudeCode) == .acceptEdits)
        #expect(reloaded.permissionMode(for: .codex) == .autoReview)
    }

    @Test("full saves retain provider overrides and discard removed ones")
    func fullSave() async throws {
        let store = try makeTestStore("provider-permissions-save")
        var defaults = AppDefaults()
        defaults.setPermissionMode(.autoReview, for: .codex)
        await defaults.save(to: store)
        #expect(await AppDefaults.load(from: store).permissionMode(for: .codex) == .autoReview)
        defaults.setPermissionMode(nil, for: .codex)
        await defaults.save(to: store)
        #expect(await AppDefaults.load(from: store).providerPermissionModes.isEmpty)
    }

    @Test("all models of a provider use its permission default")
    func resolvedModel() {
        var defaults = AppDefaults()
        defaults.setPermissionMode(.acceptEdits, for: .claudeCode)
        defaults.setPermissionMode(.autoReview, for: .codex)
        var repo = RepoSettings()
        for model in ["opus-5-1m", "sonnet", "claude-code:custom-model"] {
            repo.defaultModel = model
            #expect(ComposerDefaults.resolve(repo: repo, app: defaults).permissionMode == .acceptEdits)
        }
        for model in ["codex:gpt-test", "codex:another-model"] {
            repo.defaultModel = model
            let resolved = ComposerDefaults.resolve(repo: repo, app: defaults)
            #expect(resolved.backend == .codex)
            #expect(resolved.permissionMode == .autoReview)
        }
    }

    @Test("planning and Ask Bloom retain priority over per-provider defaults")
    func precedence() {
        var defaults = AppDefaults(planMode: true)
        defaults.setPermissionMode(.acceptEdits, for: .claudeCode)
        defaults.setPermissionMode(.autoReview, for: .codex)
        #expect(ComposerDefaults.resolve(repo: RepoSettings(), app: defaults).permissionMode == .plan)
        #expect(ComposerDefaults.resolve(repo: RepoSettings(), app: defaults, hasWorktree: false)
            .permissionMode == AskConversation.permissionMode)
        defaults.model = "gpt-test"
        defaults.backend = .codex
        let codex = ComposerDefaults.resolve(repo: RepoSettings(), app: defaults)
        #expect(codex.permissionMode == .autoReview)
        #expect(codex.interactionMode == .plan)
    }

    @Test("choosing another provider before creation applies its supported permissions")
    func createPicker() {
        var defaults = AppDefaults()
        defaults.setPermissionMode(.autoReview, for: .codex)
        var controls = ComposerControls(model: "gpt-test", agentKind: .codex)
        controls.applyPermissionDefault(from: defaults)
        #expect(controls.permissionMode == .autoReview)
        controls.model = "sonnet"
        controls.agentKind = .claudeCode
        controls.applyPermissionDefault(from: defaults)
        #expect(controls.permissionMode == .bypassPermissions)
        defaults.planMode = true
        controls.applyPermissionDefault(from: defaults)
        #expect(controls.permissionMode == .plan)
    }

    @Test("unknown stored modes do not discard valid overrides")
    func invalidStoredMode() async throws {
        let store = try makeTestStore("provider-permissions-invalid")
        try await store.setSetting(AppDefaults.permissionModeKey(for: .claudeCode), "unknown")
        try await store.setSetting(AppDefaults.permissionModeKey(for: .codex), "autoReview")
        let defaults = await AppDefaults.load(from: store)
        #expect(defaults.permissionMode(for: .claudeCode) == .bypassPermissions)
        #expect(defaults.permissionMode(for: .codex) == .autoReview)
    }
}
