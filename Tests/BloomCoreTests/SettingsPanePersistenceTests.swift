import Testing
@testable import BloomCore

@Suite("Settings pane persistence", .scratchDirectory)
struct SettingsPanePersistenceTests {
    @Test("permission edits leave unchosen model defaults unstated")
    func permissionDoesNotPinModels() async throws {
        let store = try makeTestStore("settings-permission-only")
        let previous = await AppDefaults.load(from: store)
        var edited = previous
        edited.permissionMode = .acceptEdits

        try await edited.saveChanges(from: previous, to: store)

        #expect(try await store.setting(AppDefaults.Key.model) == nil)
        #expect(try await store.setting(AppDefaults.Key.reviewModel) == nil)
        #expect(await AppDefaults.load(from: store).permissionMode == .acceptEdits)
    }

    @Test("a stale session draft cannot overwrite a newer permission choice")
    func unrelatedChangesSurvive() async throws {
        let store = try makeTestStore("settings-separate-panes")
        let previous = await AppDefaults.load(from: store)
        try await store.setSetting(AppDefaults.Key.permissionMode, PermissionMode.auto.rawValue)
        var edited = previous
        edited.fastMode = true

        try await edited.saveChanges(from: previous, to: store)

        let loaded = await AppDefaults.load(from: store)
        #expect(loaded.fastMode)
        #expect(loaded.permissionMode == .auto)
        #expect(loaded.storedModel == nil)
    }

    @Test("switching the default backend preserves the displayed review model")
    func modelPairsStayTogether() async throws {
        let store = try makeTestStore("settings-model-pairs")
        let previous = await AppDefaults.load(from: store)
        var edited = previous
        edited.model = "gpt-test"
        edited.backend = .codex
        edited.effort = "medium"

        try await edited.saveChanges(from: previous, to: store)

        let loaded = await AppDefaults.load(from: store)
        #expect(loaded.model == "gpt-test")
        #expect(loaded.backend == .codex)
        #expect(loaded.effort == "medium")
        #expect(loaded.reviewModel == previous.reviewModel)
        #expect(loaded.reviewBackend == previous.reviewBackend)
        #expect(loaded.reviewEffort == previous.reviewEffort)
    }

    @Test("restoring provider defaults removes their overrides")
    func providerDefaultsClearStorage() async throws {
        let store = try makeTestStore("settings-provider-reset")
        try await store.setSetting(AppDefaults.Key.outputStyle, "concise")
        try await store.setSetting(AppDefaults.Key.codexContextWindow, "1000000")
        let previous = await AppDefaults.load(from: store)
        var edited = previous
        edited.outputStyle = OutputStyle.defaultName
        edited.codexContextWindow = CodexContextWindow.modelDefault

        try await edited.saveChanges(from: previous, to: store)

        #expect(try await store.setting(AppDefaults.Key.outputStyle) == nil)
        #expect(try await store.setting(AppDefaults.Key.codexContextWindow) == nil)
    }
}
