import Testing
import Foundation
@testable import BatonCore

/// Baton reads Conductor's settings files as they are, and those name models in Conductor's own
/// vocabulary. The `claude` CLI does not share it. A machine whose `~/.conductor/settings.toml`
/// pinned `opus-5-1m` produced workspaces whose first turn died with "There's an issue with the
/// selected model (opus-5-1m)", so every model string is translated on its way to the CLI.
///
/// The expectations below were checked against the real binary: `opus-5-1m` is rejected,
/// `claude-opus-5[1m]` and `opus` are accepted.
@Suite("Model aliases")
struct ModelAliasTests {
    @Test("translates the Conductor id that was breaking every run")
    func translatesTheBrokenOne() {
        #expect(ModelAlias.cliValue(for: "opus-5-1m") == "claude-opus-5[1m]")
    }

    @Test("translates the rest of the Conductor family names")
    func translatesTheFamily() {
        #expect(ModelAlias.cliValue(for: "opus-5") == "claude-opus-5")
        #expect(ModelAlias.cliValue(for: "sonnet-5") == "claude-sonnet-5")
        #expect(ModelAlias.cliValue(for: "haiku-4-5") == "claude-haiku-4-5")
        #expect(ModelAlias.cliValue(for: "sonnet-5-1m") == "claude-sonnet-5[1m]")
    }

    @Test("leaves the CLI's own shorthand alone")
    func leavesShorthandAlone() {
        #expect(ModelAlias.cliValue(for: "opus") == "opus")
        #expect(ModelAlias.cliValue(for: "sonnet") == "sonnet")
        #expect(ModelAlias.cliValue(for: "haiku") == "haiku")
    }

    @Test("leaves a fully qualified id alone")
    func leavesQualifiedAlone() {
        // Someone who typed an exact build knows what they want, and rewriting it would be worse
        // than passing it through.
        #expect(ModelAlias.cliValue(for: "claude-opus-5") == "claude-opus-5")
        #expect(ModelAlias.cliValue(for: "claude-opus-5[1m]") == "claude-opus-5[1m]")
        #expect(ModelAlias.cliValue(for: "claude-haiku-4-5-20251001") == "claude-haiku-4-5-20251001")
    }

    @Test("falls back rather than guessing")
    func fallsBack() {
        // Empty means "nothing was chosen", which is the one case where a default is right.
        #expect(ModelAlias.cliValue(for: "") == "opus")
        #expect(ModelAlias.cliValue(for: "   ") == "opus")
        // An id in no shape we recognise is passed through: turning it into something else would
        // break a model the CLI might well accept.
        #expect(ModelAlias.cliValue(for: "gpt-5") == "gpt-5")
        #expect(ModelAlias.cliValue(for: "opus-next") == "opus-next")
    }

    @Test("normalises whitespace and case")
    func normalises() {
        #expect(ModelAlias.cliValue(for: "  Opus-5-1M  ") == "claude-opus-5[1m]")
        #expect(ModelAlias.cliValue(for: "OPUS") == "opus")
    }

    @Test("the runner sends the translated value, not the stored one")
    func runnerTranslates() {
        let session = Session(workspaceID: "w", model: "opus-5-1m")
        let argv = AgentRunner.argv(session: session, resume: nil)
        guard let index = argv.firstIndex(of: "--model") else {
            Issue.record("argv carries no --model")
            return
        }
        #expect(argv[index + 1] == "claude-opus-5[1m]")
        #expect(!argv.contains("opus-5-1m"))
    }

    @Test("never produces an empty model argument")
    func neverEmpty() {
        for raw in ["", " ", "opus", "opus-5-1m", "claude-opus-5", "nonsense"] {
            #expect(!ModelAlias.cliValue(for: raw).isEmpty)
        }
    }
}
