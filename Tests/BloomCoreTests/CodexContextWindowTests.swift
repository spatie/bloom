import Testing
@testable import BloomCore

/// The bug this file is about: a Codex chat runs on whatever window Codex's own catalogue says,
/// which is well under what the model takes, and the only way past it is two config overrides that
/// have to agree with each other.
@Suite("Codex's context window")
struct CodexContextWindowTests {
    @Test func writesBothKeysBecauseOneOnItsOwnIsWorseThanNeither() {
        let overrides = CodexContextWindow.overrides(for: 1_000_000)

        #expect(overrides == [
            "-c", "model_context_window=1000000",
            "-c", "model_auto_compact_token_limit=900000",
        ])
    }

    @Test func theModelsOwnWindowAddsNoArguments() {
        #expect(CodexContextWindow.overrides(for: CodexContextWindow.modelDefault).isEmpty)
        #expect(CodexContextWindow.autoCompactLimit(for: CodexContextWindow.modelDefault) == 0)
    }

    @Test func compactionIsBelowTheWindowAtEverySizeOffered() {
        for tokens in CodexContextWindow.choices where tokens > 0 {
            let limit = CodexContextWindow.autoCompactLimit(for: tokens)
            #expect(limit > 0)
            #expect(limit < tokens)
        }
    }

    @Test func readsTheRoundNumbersTheWayTheyAreAskedFor() {
        #expect(CodexContextWindow.label(for: 0) == "Default")
        #expect(CodexContextWindow.label(for: 500_000) == "500K")
        #expect(CodexContextWindow.label(for: 1_000_000) == "1M")
        #expect(CodexContextWindow.label(for: 2_500_000) == "2500K")
        #expect(CodexContextWindow.label(for: 512) == "512")
    }

    /// A row nobody can parse must not size a context, and neither must a negative one.
    @Test func anythingUnreadableIsTheModelsOwnWindow() {
        #expect(CodexContextWindow.normalised(nil) == 0)
        #expect(CodexContextWindow.normalised("") == 0)
        #expect(CodexContextWindow.normalised("lots") == 0)
        #expect(CodexContextWindow.normalised("-1") == 0)
        #expect(CodexContextWindow.normalised("0") == 0)
        #expect(CodexContextWindow.normalised(" 1000000 ") == 1_000_000)
    }

    /// "Never chosen" and "chosen and then set back" have to read the same, which is why the
    /// default is stored as no row rather than as a zero.
    @Test func theDefaultIsStoredAsNoRow() {
        #expect(CodexContextWindow.stored(CodexContextWindow.modelDefault) == nil)
        #expect(CodexContextWindow.stored(500_000) == "500000")
    }

    /// A size set by an older build or a settings file stays on the list, so the picker can put it
    /// back. Same rule, and the same one-way door, as `ComposerOption.adding`.
    @Test func aSizeTheListDoesNotHoldIsStillOffered() {
        #expect(CodexContextWindow.options(including: 400_000) == [0, 400_000, 500_000, 1_000_000])
        #expect(CodexContextWindow.options(including: 500_000) == CodexContextWindow.choices)
        #expect(CodexContextWindow.options(including: 0) == CodexContextWindow.choices)
    }

    @Test func onlyCodexIsOfferedTheChoice() {
        #expect(ComposerControls(agentKind: .codex).offersContextWindow)
        #expect(!ComposerControls(agentKind: .claudeCode).offersContextWindow)
    }

    /// The overrides belong to the `app-server` subcommand, so they follow it, beside the bridge's
    /// own. See `CodexClient.launch`.
    @Test func reachesTheServerAfterTheSubcommand() {
        let launch = CodexClient.launch(CodexClient.Configuration(
            cwd: "/tmp/w", environment: [:], contextWindow: 1_000_000
        ))

        #expect(launch.arguments.prefix(3) == ["app-server", "--listen", "stdio://"])
        #expect(launch.arguments.contains("model_context_window=1000000"))
        #expect(launch.arguments.contains("model_auto_compact_token_limit=900000"))
    }

    @Test func aServerLeftOnTheModelsOwnWindowIsLaunchedExactlyAsBefore() {
        let launch = CodexClient.launch(CodexClient.Configuration(cwd: "/tmp/w", environment: [:]))

        #expect(launch.arguments == ["app-server", "--listen", "stdio://"])
    }
}
