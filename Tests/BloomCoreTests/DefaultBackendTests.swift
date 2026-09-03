import Testing
import Foundation
@testable import BloomCore

/// Which CLI a chat opened from the app-wide defaults runs on.
///
/// The screen offered Claude Code's four models and stored a bare name, so an owner who works in
/// Codex had to move every new chat by hand; the model list in Settings and the one in the
/// composer's footer were two different lists, and only one of them knew Codex existed. The rule
/// that closes that is `DefaultBackend`, and what it has to survive is the awkward half: Codex's
/// models are **fetched**, so the answer has to be right offline, on a machine with no Codex
/// installed, and in the second before `model/list` comes back.
///
/// That is why the recorded backend is asked for first and the lists second. Every test below is
/// one of the states that shape had to be right in.
@Suite("The backend a new chat opens on", .scratchDirectory)
struct DefaultBackendTests {
    /// Two models and the levels they really take, measured against codex-cli 0.147.0 and quoted
    /// in `CodexModelCatalog`: six for `gpt-5.6-sol` including `ultra`, four for `gpt-5.5`.
    static let codexModels = [
        CodexModel(
            id: "gpt-5.6-sol",
            displayName: "GPT-5.6 Sol",
            supportedEfforts: ["none", "low", "medium", "high", "xhigh", "ultra"]
                .map { CodexReasoningEffort(id: $0) },
            defaultEffort: "low"
        ),
        CodexModel(
            id: "gpt-5.5",
            displayName: "GPT-5.5",
            supportedEfforts: ["low", "medium", "high", "xhigh"]
                .map { CodexReasoningEffort(id: $0) },
            defaultEffort: "medium"
        ),
    ]

    // MARK: - What is already stored

    /// Every value written before `defaults.backend` existed is one of Claude Code's four models
    /// with no backend beside it, because those were the only rows the screen had. Nothing is
    /// migrated, so this is the test that says the absence reads correctly.
    @Test("a model stored before the key existed still opens Claude Code")
    func aStoredModelWithNoBackendIsClaudeCode() async throws {
        let store = try makeTestStore("default-backend-legacy")
        try await store.setSetting(AppDefaults.Key.model, "sonnet")
        try await store.setSetting(AppDefaults.Key.effort, "medium")

        let defaults = await AppDefaults.load(from: store)
        #expect(defaults.backend == .claudeCode)

        let resolved = ComposerDefaults.resolve(repo: RepoSettings(), app: defaults)
        #expect(resolved.model == "sonnet")
        #expect(resolved.backend == .claudeCode)
    }

    /// The point of storing the backend rather than deriving it: no list is consulted, so the
    /// answer is the same whether or not `model/list` has ever answered on this machine.
    @Test("a Codex model chosen in Settings opens Codex with nothing fetched")
    func aStoredCodexModelOpensCodex() async throws {
        let store = try makeTestStore("default-backend-codex")
        await AppDefaults(model: "gpt-5.6-sol", effort: "high", backend: .codex).save(to: store)

        let defaults = await AppDefaults.load(from: store)
        #expect(defaults.backend == .codex)

        let resolved = ComposerDefaults.resolve(repo: RepoSettings(), app: defaults)
        #expect(resolved.model == "gpt-5.6-sol")
        #expect(resolved.backend == .codex)
    }

    /// The review row is a second model with a second backend, and it falls back to the first
    /// row's rather than to Claude Code, so a copy of Bloom that was set up before either key
    /// existed keeps one coherent pair.
    @Test("the review model carries its own backend and inherits the other when it has none")
    func theReviewRowHasABackendOfItsOwn() async throws {
        let store = try makeTestStore("default-backend-review")
        try await store.setSetting(AppDefaults.Key.backend, AgentKind.codex.rawValue)

        var defaults = await AppDefaults.load(from: store)
        #expect(defaults.reviewBackend == .codex)

        defaults.reviewBackend = .claudeCode
        defaults.reviewModel = "opus"
        await defaults.save(to: store)
        #expect(await AppDefaults.load(from: store).reviewBackend == .claudeCode)
    }

    // MARK: - What the model itself says

    /// The question that decides a model which never came from this screen. A repository's
    /// `models.default` outranks the app defaults, so a project pinning a GPT model has to move
    /// the backend with it or the chat opens on a CLI that has never heard of the model.
    @Test("a repository pinning a Codex model moves the backend with it")
    func aRepoPinnedCodexModelWins() {
        var repo = RepoSettings()
        repo.defaultModel = "gpt-5.5"

        let resolved = ComposerDefaults.resolve(
            repo: repo,
            app: AppDefaults(),
            codexModels: Self.codexModels
        )
        #expect(resolved.model == "gpt-5.5")
        #expect(resolved.backend == .codex)
    }

    /// The other direction, which is the one that would be a real accident: an owner whose default
    /// is Codex opening a project that pins Opus must not get Opus on Codex.
    @Test("a repository pinning a Claude model moves it back")
    func aRepoPinnedClaudeModelWins() {
        var repo = RepoSettings()
        repo.defaultModel = "claude-opus-5[1m]"

        let resolved = ComposerDefaults.resolve(
            repo: repo,
            app: AppDefaults(model: "gpt-5.6-sol", backend: .codex),
            codexModels: Self.codexModels
        )
        #expect(resolved.backend == .claudeCode)
    }

    /// An id no list holds, which is an ordinary thing for a settings file to state. It stays
    /// where it is rather than moving a chat somewhere nobody asked for.
    @Test("a model neither list holds stays on the backend already running")
    func anUnknownModelDoesNotMoveAnything() {
        var repo = RepoSettings()
        repo.defaultModel = "internal-preview-3"

        let opened = ComposerDefaults.resolve(
            repo: repo,
            app: AppDefaults(),
            codexModels: Self.codexModels
        )
        #expect(opened.backend == .claudeCode)

        let inACodexChat = ComposerDefaults.resolve(
            repo: repo,
            app: AppDefaults(),
            running: .codex,
            codexModels: Self.codexModels
        )
        #expect(inACodexChat.backend == .codex)
    }

    // MARK: - A model that names its own backend

    /// The reported bug, at the layer it entered by. A settings file has one key for a model and
    /// two CLIs to name one for, so it can write the backend in front of the id, and
    /// `codex:gpt-5.6-sol` is what a real one held. Read as an opaque id it matched nothing, so
    /// the last question parked a Codex model on Claude Code and the chat ran on Claude Code's
    /// own default. See `ModelIdentifier`.
    @Test("a settings file naming the backend in front of the model opens that backend")
    func aNamespacedRepoModelOpensItsOwnBackend() {
        var repo = RepoSettings()
        repo.defaultModel = "codex:gpt-5.6-sol"

        let resolved = ComposerDefaults.resolve(
            repo: repo,
            app: AppDefaults(),
            codexModels: Self.codexModels
        )
        #expect(resolved.model == "gpt-5.6-sol")
        #expect(resolved.backend == .codex)
    }

    /// And it does so with nothing fetched, which is the property the whole ordering exists for:
    /// a machine that is offline, or has no Codex on it, must still open the chat where the file
    /// said rather than somewhere a missing list left it.
    @Test("it opens that backend before any list has answered")
    func aNamespacedModelNeedsNoList() {
        var repo = RepoSettings()
        repo.defaultModel = "codex:gpt-5.6-sol"

        let resolved = ComposerDefaults.resolve(repo: repo, app: AppDefaults())
        #expect(resolved.model == "gpt-5.6-sol")
        #expect(resolved.backend == .codex)
    }

    /// A machine-wide `~/.conductor/settings.toml` is the other file that can hold one, and it
    /// sits below the Settings screen rather than above it, so this only applies when the screen
    /// has never been used.
    @Test("the machine-wide file is read the same way")
    func aNamespacedHomeModel() {
        var repo = RepoSettings()
        repo.homeDefaultModel = "codex:gpt-5.5"

        let resolved = ComposerDefaults.resolve(
            repo: repo,
            app: AppDefaults(),
            codexModels: Self.codexModels
        )
        #expect(resolved.model == "gpt-5.5")
        #expect(resolved.backend == .codex)
    }

    /// A string that states its backend beats one merely recorded beside it. The recorded value
    /// is what the screen last wrote, and it can be older than the file: an id saying `codex:` is
    /// stating the answer rather than implying it.
    @Test("the name in front of the model beats the backend stored beside it")
    func theNamespaceBeatsTheRecordedBackend() {
        let stale = AppDefaults(model: "codex:gpt-5.6-sol", backend: .claudeCode)
        let resolved = ComposerDefaults.resolve(
            repo: RepoSettings(),
            app: stale,
            codexModels: Self.codexModels
        )
        #expect(resolved.model == "gpt-5.6-sol")
        #expect(resolved.backend == .codex)
    }

    /// The menu asks the same question of the same string, which is what makes the fault
    /// recoverable: the stuck chat's model lands in the Codex section, where picking another
    /// Codex model is an ordinary change in place rather than a move between backends.
    @Test("the model menu places it in the same section")
    func theMenuPlacesItTheSameWay() {
        #expect(DefaultBackend.kind(
            ofModel: "codex:gpt-5.6-sol", running: .claudeCode, codexModels: Self.codexModels
        ) == .codex)
        #expect(DefaultBackend.kind(
            ofModel: "claude:opus", running: .codex, codexModels: Self.codexModels
        ) == .claudeCode)
    }

    /// `ClaudeModelRank` is what answers "is this one of ours", and it answers for the ids the
    /// menu does not list as well as for the four it does.
    @Test("the four families are recognised, including the variants no menu row carries")
    func theFamiliesAreRecognised() {
        #expect(ClaudeModelRank.recognises("opus"))
        #expect(ClaudeModelRank.recognises("claude-opus-5[1m]"))
        #expect(ClaudeModelRank.recognises("opus-5-1m"))
        #expect(!ClaudeModelRank.recognises("gpt-5.6-sol"))
        #expect(!ClaudeModelRank.recognises("internal-preview-3"))
    }

    // MARK: - The effort, which on Codex belongs to the model

    /// `max` is a level Claude Code takes and `gpt-5.5` does not, and it is exactly what an owner
    /// who set the default before switching backends is carrying. It lands on that model's own
    /// default rather than on a value the server would refuse.
    @Test("an effort the chosen model does not take falls to the model's default")
    func anImpossibleEffortFallsBack() {
        let resolved = ComposerDefaults.resolve(
            repo: RepoSettings(),
            app: AppDefaults(model: "gpt-5.5", effort: "max", backend: .codex),
            codexModels: Self.codexModels
        )
        #expect(resolved.effort == "medium")

        let takesIt = ComposerDefaults.resolve(
            repo: RepoSettings(),
            app: AppDefaults(model: "gpt-5.6-sol", effort: "ultra", backend: .codex),
            codexModels: Self.codexModels
        )
        #expect(takesIt.effort == "ultra")
    }

    /// With no list fetched there is nothing to check the level against, and inventing a fallback
    /// would be Bloom overruling a stored choice on no evidence.
    @Test("an effort is left alone while the list has not arrived")
    func anEffortIsKeptWithNoList() {
        let resolved = ComposerDefaults.resolve(
            repo: RepoSettings(),
            app: AppDefaults(model: "gpt-5.5", effort: "max", backend: .codex)
        )
        #expect(resolved.effort == "max")
        #expect(resolved.backend == .codex)
    }

    // MARK: - The permission mode follows the backend

    /// "Start new sessions in plan mode" is one app-wide switch above two model rows, so it is set
    /// long before this chat's backend is known. Codex has no Plan, and the mode a chat is written
    /// with has to be one its backend has a row for.
    @Test("plan mode cannot reach a chat opened on Codex")
    func planModeNeverReachesCodex() {
        var codex = AppDefaults(model: "gpt-5.6-sol", backend: .codex)
        codex.planMode = true
        #expect(ComposerDefaults.resolve(repo: RepoSettings(), app: codex).permissionMode == .auto)

        var claude = AppDefaults()
        claude.planMode = true
        #expect(ComposerDefaults.resolve(repo: RepoSettings(), app: claude).permissionMode == .plan)
    }

    /// The same rule one layer up, where the value actually reaches a session row: whatever the
    /// mode was, `ComposerControls` holds it to one the backend has.
    @Test("the controls a workspace is started with hold the same invariant")
    func theControlsLandOnALegalMode() {
        var defaults = AppDefaults(model: "gpt-5.6-sol", backend: .codex)
        defaults.planMode = true

        let controls = ComposerControls(
            defaults: ComposerDefaults.resolve(repo: RepoSettings(), app: defaults),
            isFastMode: false,
            outputStyle: OutputStyle.defaultName
        )
        #expect(controls.agentKind == .codex)
        #expect(controls.permissionMode == .auto)
        #expect(!controls.offersOutputStyle)
    }
}
