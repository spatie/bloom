import Testing
import Foundation
@testable import BloomCore

/// The bug this suite is written from, reported with two screenshots of the composer's model menu.
///
/// The menu had its two sections, Claude Code and Codex, and a **fifth row inside the Claude Code
/// section reading "Codex:gpt 5.6 Sol"**, ticked. The chat ran on Claude Code's default rather
/// than on anything the menu said, and changing the model in Settings, Models put the same row
/// straight back.
///
/// That row's text is the whole diagnosis, and the first test below pins it: it is
/// `ModelLabel.readable("codex:gpt-5.6-sol")`, so the stored id was `codex:gpt-5.6-sol`, a model
/// with its backend written in front of it. Nothing in Bloom composes that string; it arrives
/// verbatim from a settings file's `models.default`, which `ComposerDefaults.resolve` ranks above
/// the Settings screen and `ComposerView.prepare` writes onto the session row.
@Suite("A model id that names its own backend")
struct ModelIdentifierTests {
    /// The account's real list, as `DefaultBackendTests` quotes it, because the label reading
    /// below can only answer from what the account actually offers.
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

    // MARK: - The string in the report

    /// The row in the screenshot, drawn from the id that was stored. This is the test that says
    /// which string the report was about, and it is why everything below names that string.
    @Test("the row the user photographed is what this id renders as")
    func theReportedRow() {
        #expect(ModelLabel.readable("codex:gpt-5.6-sol") == "Codex:gpt 5.6 Sol")
    }

    @Test("the backend in front of the id is read rather than stored")
    func theNamespaceIsRead() {
        let resolved = ModelIdentifier.resolve("codex:gpt-5.6-sol", codexModels: Self.codexModels)
        #expect(resolved.model == "gpt-5.6-sol")
        #expect(resolved.kind == .codex)
        #expect(resolved.namesBackend)
    }

    /// With no list fetched, which is every machine that is offline, has no Codex installed, or
    /// has simply not opened a model menu yet. The name in front of the colon needs no list, and
    /// that is the reason it is trusted before anything is looked up.
    @Test("it needs no fetched list")
    func theNamespaceNeedsNoList() {
        let resolved = ModelIdentifier.resolve("codex:gpt-5.6-sol")
        #expect(resolved.model == "gpt-5.6-sol")
        #expect(resolved.kind == .codex)
    }

    /// The three spellings a file could reasonably use for one backend, all read the same.
    @Test("a backend is named by its key, its name or its command", arguments: [
        ("codex:gpt-5.5", AgentKind.codex, "gpt-5.5"),
        ("Codex: gpt-5.5", AgentKind.codex, "gpt-5.5"),
        ("claudeCode:opus", AgentKind.claudeCode, "opus"),
        ("claude-code:opus", AgentKind.claudeCode, "opus"),
        ("Claude Code:opus", AgentKind.claudeCode, "opus"),
        ("claude:opus", AgentKind.claudeCode, "opus"),
    ])
    func theSpellings(raw: String, kind: AgentKind, model: String) {
        let resolved = ModelIdentifier.resolve(raw, codexModels: Self.codexModels)
        #expect(resolved.kind == kind)
        #expect(resolved.model == model)
        #expect(resolved.namesBackend)
    }

    // MARK: - A label written where an id belongs

    /// The other half of the fault: what the menu draws is not what the CLI takes, and a rendered
    /// name reaching a model column is a chat that cannot start. Read back off the account's own
    /// list, so nothing is invented from prose alone.
    @Test("a rendered label is read back as the id it was drawn from", arguments: [
        "Codex:gpt 5.6 Sol",
        "codex:GPT-5.6 Sol",
        "GPT-5.6 Sol",
        "gpt 5.6 sol",
    ])
    func aLabelIsReadBack(raw: String) {
        let resolved = ModelIdentifier.resolve(raw, codexModels: Self.codexModels)
        #expect(resolved.model == "gpt-5.6-sol")
        #expect(resolved.kind == .codex)
    }

    /// With nothing fetched there is no list to read a label against, so the backend the string
    /// states is still honoured and the id is left as it stands. That is enough to recover: the
    /// menu draws the chat in the Codex section, where every row is one press from correct.
    @Test("a label with no list keeps its backend and waits")
    func aLabelWithNoList() {
        let resolved = ModelIdentifier.resolve("Codex:gpt 5.6 Sol")
        #expect(resolved.kind == .codex)
        #expect(resolved.model == "gpt 5.6 Sol")
    }

    // MARK: - What must not be touched

    /// The open set this rule had to be safe for. No id either CLI ships has a colon in it, and
    /// nothing here has one, so nothing here changes.
    @Test("real ids pass through untouched", arguments: [
        "opus", "sonnet", "fable", "haiku",
        "claude-opus-5", "claude-opus-5[1m]", "opus-5-1m", "claude-haiku-4-5-20251001",
        "gpt-5.6-sol", "gpt-5.5", "gpt-5.3-codex-spark",
        "internal-preview-3",
    ])
    func realIDsSurvive(id: String) {
        #expect(ModelIdentifier.resolve(id, codexModels: Self.codexModels).model == id)
        #expect(!ModelIdentifier.resolve(id, codexModels: Self.codexModels).namesBackend)
    }

    /// A colon whose left side is not a backend Bloom has. Some other tool's namespace is not
    /// Bloom's to unpick, and the open-set rule stands: keep it, show it, let it be changed.
    @Test("a namespace that is not a backend is left alone")
    func anUnknownNamespaceSurvives() {
        let resolved = ModelIdentifier.resolve("openrouter:openai/gpt-4", codexModels: Self.codexModels)
        #expect(resolved.model == "openrouter:openai/gpt-4")
        #expect(resolved.kind == nil)
        #expect(!resolved.namesBackend)
    }

    /// Nothing to name a model with, so there is nothing to take a name off.
    @Test("a bare backend name is not a model")
    func aBareBackendName() {
        #expect(ModelIdentifier.resolve("codex:").model == "codex:")
        #expect(ModelIdentifier.resolve("").model == "")
    }

    // MARK: - Getting a stuck chat back

    /// The chat in the report: a Claude Code row holding a Codex id, which has never opened a
    /// thread. Both halves are corrected, and it opens where the id said all along.
    @Test("a chat that has not spoken is put on the backend its model names")
    func aFreshChatIsMoved() throws {
        let repair = try #require(ModelIdentifier.correction(
            model: "codex:gpt-5.6-sol",
            on: .claudeCode,
            hasSpoken: false,
            codexModels: Self.codexModels
        ))
        #expect(repair.model == "gpt-5.6-sol")
        #expect(repair.kind == .codex)
    }

    /// The same row on a chat with a thread on Claude Code's server. The id is corrected, because
    /// an id that is not an id can only fail; the backend is not, because the transcript and the
    /// thread are Claude Code's and moving them is what `BackendChange` forks rather than does.
    @Test("a chat that has spoken keeps its backend and still gets a usable id")
    func aSpokenChatKeepsItsBackend() throws {
        let repair = try #require(ModelIdentifier.correction(
            model: "codex:gpt-5.6-sol",
            on: .claudeCode,
            hasSpoken: true,
            codexModels: Self.codexModels
        ))
        #expect(repair.model == "gpt-5.6-sol")
        #expect(repair.kind == .claudeCode)
    }

    /// Nothing to do is nothing written. The composer runs this on every chat it opens, so a rule
    /// that answered on a healthy row would be a write on every tab switch.
    @Test("a chat that is already right is left alone", arguments: [
        "opus", "claude-opus-5[1m]", "gpt-5.6-sol", "internal-preview-3",
    ])
    func nothingToCorrect(model: String) {
        #expect(ModelIdentifier.correction(
            model: model,
            on: .claudeCode,
            hasSpoken: false,
            codexModels: Self.codexModels
        ) == nil)
    }

    /// The one that makes a stuck chat recoverable rather than merely tidy. Whatever the row was
    /// holding, once it has been read the model menu asks `DefaultBackend` the same question and
    /// gets the Codex section, so the next press is an ordinary same-backend change instead of a
    /// press on a row that answers Claude Code and writes Codex.
    @Test("the menu and the defaults agree about the id after it is read")
    func theMenuAgrees() {
        let stuck = "codex:gpt-5.6-sol"
        #expect(DefaultBackend.kind(
            ofModel: stuck, running: .claudeCode, codexModels: Self.codexModels
        ) == .codex)

        let repaired = ModelIdentifier.resolve(stuck, codexModels: Self.codexModels).model
        #expect(DefaultBackend.kind(
            ofModel: repaired, running: .claudeCode, codexModels: Self.codexModels
        ) == .codex)
    }
}
