import Foundation
import Testing
@testable import BloomCore

/// The bug this file is about: `claude-opus-4-6` rendered as "Opus 4 6" on every session-start
/// row, because the separator a version uses is the one thing the id has already thrown away.
@Suite("Model labels")
struct ModelLabelTests {
    @Test("a version keeps its full stop rather than becoming two words")
    func versionsAreRejoined() {
        #expect(ModelLabel.readable("claude-opus-4-6") == "Opus 4.6")
        #expect(ModelLabel.readable("claude-opus-4-5") == "Opus 4.5")
        #expect(ModelLabel.readable("claude-sonnet-4-5-20251001") == "Sonnet 4.5.20251001")
    }

    @Test("a single version part is left as it was")
    func singleVersionPart() {
        #expect(ModelLabel.readable("claude-opus-5") == "Opus 5")
        #expect(ModelLabel.readable("claude-fable-5") == "Fable 5")
    }

    /// A context window is not a version part, and "5.1m" would read as a version this model does
    /// not have.
    @Test("a context window stays a separate word")
    func contextWindowsAreNotVersions() {
        #expect(ModelLabel.readable("opus-5-1m") == "Opus 5 1m")
        #expect(ModelLabel.readable("claude-opus-5[1m]") == "Opus 5 (1m)")
    }

    @Test("the vendor prefix goes, because inside Bloom every model is a Claude model")
    func vendorIsDropped() {
        #expect(ModelLabel.readable("claude-haiku-4-5") == "Haiku 4.5")
    }

    @Test("unless the vendor name is all there is, which would leave nothing to read")
    func vendorAloneSurvives() {
        #expect(ModelLabel.readable("claude") == "Claude")
    }

    @Test("a permission mode reads as a mode")
    func permissionModes() {
        #expect(ModelLabel.readable("acceptEdits") == "AcceptEdits")
        #expect(ModelLabel.readable("bypass_permissions") == "Bypass Permissions")
    }

    @Test("an id with nothing in it comes back as it went in rather than as an empty chip")
    func emptyIsUnchanged() {
        #expect(ModelLabel.readable("") == "")
        #expect(ModelLabel.readable("---") == "---")
    }

    @Test("a part that does not start with a letter is not capitalised into nonsense")
    func nonLettersAreLeftAlone() {
        #expect(ModelLabel.readable("gpt-5-codex") == "GPT 5 Codex")
        #expect(ModelLabel.readable("gpt-5-6-luna") == "GPT 5.6 Luna")
        #expect(ModelLabel.readable("o3-mini") == "O3 Mini")
    }
}
