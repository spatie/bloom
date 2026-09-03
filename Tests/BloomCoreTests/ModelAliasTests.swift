import Testing
import Foundation
@testable import BloomCore

/// Bloom reads Conductor's settings files as they are, and those name models in Conductor's own
/// vocabulary. The `claude` CLI does not share it. A machine whose `~/.conductor/settings.toml`
/// pinned `opus-5-1m` produced workspaces whose first turn died with "There's an issue with the
/// selected model (opus-5-1m)", so every model string is translated on its way to the CLI.
///
/// The expectations below were checked against the real binary: `opus-5-1m` is rejected,
/// `claude-opus-5[1m]` and `opus` are accepted.
@Suite("Model aliases", .tags(.agentProtocol))
struct ModelAliasTests {
    @Test("translates the Conductor id that was breaking every run")
    func translatesTheBrokenOne() {
        #expect(ModelAlias.cliValue(for: "opus-5-1m") == "claude-opus-5[1m]")
    }

    @Test("translates a Conductor family name into the id the CLI accepts", arguments: [
        ("opus-5", "claude-opus-5"),
        ("sonnet-5", "claude-sonnet-5"),
        ("haiku-4-5", "claude-haiku-4-5"),
        ("sonnet-5-1m", "claude-sonnet-5[1m]"),
        ("fable-5-1", "claude-fable-5-1"),
    ])
    func translatesTheFamily(conductorID: String, cliID: String) {
        #expect(ModelAlias.cliValue(for: conductorID) == cliID)
    }

    @Test("leaves alone anything the CLI already understands", arguments: [
        // The CLI's own shorthand.
        "opus", "sonnet", "fable", "haiku",
        // Someone who typed an exact build knows what they want, and rewriting it would be worse
        // than passing it through.
        "claude-opus-5", "claude-opus-5[1m]", "claude-haiku-4-5-20251001",
    ])
    func leavesKnownIDsAlone(modelID: String) {
        #expect(ModelAlias.cliValue(for: modelID) == modelID)
    }

    @Test("falls back to opus only when nothing was chosen", arguments: ["", "   ", "\t\n"])
    func fallsBackForBlankInput(blank: String) {
        #expect(ModelAlias.cliValue(for: blank) == "opus")
    }

    @Test("passes an unrecognised id through rather than guessing", arguments: ["gpt-5", "opus-next"])
    func passesUnknownIDsThrough(modelID: String) {
        // Turning it into something else would break a model the CLI might well accept.
        #expect(ModelAlias.cliValue(for: modelID) == modelID)
    }

    @Test("normalises whitespace and case", arguments: [
        ("  Opus-5-1M  ", "claude-opus-5[1m]"),
        ("OPUS", "opus"),
        ("\tsonnet-5\n", "claude-sonnet-5"),
    ])
    func normalises(input: String, expected: String) {
        #expect(ModelAlias.cliValue(for: input) == expected)
    }

    @Test("the runner sends the translated value, not the stored one")
    func runnerTranslates() throws {
        let session = Session(workspaceID: WorkspaceID("w"), model: "opus-5-1m")
        let argv = AgentRunner.argv(session: session, resume: nil)
        let index = try #require(argv.firstIndex(of: "--model"), "argv carries no --model")
        #expect(argv[index + 1] == "claude-opus-5[1m]")
        #expect(argv.contains("opus-5-1m") == false)
    }

    /// Two shapes that are not ids at all, and the last place either can be stopped before it
    /// becomes an argument. A session row written before `ModelIdentifier` existed still holds
    /// one, so this gate is what lets that chat start rather than waiting to be opened and
    /// corrected. See that type's head for how `codex:gpt-5.6-sol` came to be on a row.
    @Test("a backend written in front of the id is not part of the id", arguments: [
        ("claude:opus", "opus"),
        ("claudeCode:opus-5-1m", "claude-opus-5[1m]"),
        ("Claude Code: sonnet", "sonnet"),
        // Not this CLI's model at all, so it is handed over as it stands rather than guessed at.
        // What matters is that the backend's name has gone: `codex:gpt-5.6-sol` is not an id
        // anything accepts, and `gpt-5.6-sol` at least names a real model.
        ("codex:gpt-5.6-sol", "gpt-5.6-sol"),
    ])
    func dropsTheBackendName(raw: String, expected: String) {
        #expect(ModelAlias.cliValue(for: raw) == expected)
    }

    /// A rendered label reaching the model column, which is the other way a value that is not an
    /// id gets stored. The spaces are where the separators were, so they become separators again.
    @Test("a label's spaces become the separators the id had", arguments: [
        ("Opus 5", "claude-opus-5"),
        ("opus 5 1m", "claude-opus-5[1m]"),
    ])
    func readsALabelBack(raw: String, expected: String) {
        #expect(ModelAlias.cliValue(for: raw) == expected)
    }

    @Test("never produces an empty model argument", arguments: [
        "", " ", "opus", "opus-5-1m", "claude-opus-5", "nonsense",
    ])
    func neverEmpty(raw: String) {
        #expect(ModelAlias.cliValue(for: raw).isEmpty == false)
    }
}
