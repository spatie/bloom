import Foundation
import Testing
@testable import BloomCore

/// The bug this file is about: the model menu opened with Opus, put Fable third, and drew the
/// model the chat was actually pinned to underneath Haiku.
@Suite("Claude model rank")
struct ClaudeModelRankTests {
    @Test("the four are offered most expensive first")
    func familiesRunByPrice() {
        let ordered = ClaudeModelRank.ordered(["opus", "sonnet", "fable", "haiku"])

        #expect(ordered == ["fable", "opus", "sonnet", "haiku"])
    }

    /// The one that sent the owner to the menu in the first place.
    @Test("a pinned long-context id sits with its own family rather than at the end")
    func pinnedVariantJoinsItsFamily() {
        let ordered = ClaudeModelRank.ordered(
            ["fable", "opus", "sonnet", "haiku", "claude-opus-5[1m]"]
        )

        #expect(ordered == ["fable", "opus", "claude-opus-5[1m]", "sonnet", "haiku"])
    }

    @Test("Conductor's spelling of the same variant lands in the same place")
    func conductorSpelling() {
        let ordered = ClaudeModelRank.ordered(["sonnet", "opus-5-1m", "opus"])

        #expect(ordered == ["opus", "opus-5-1m", "sonnet"])
    }

    @Test("the bare family name outranks any version of it, because it is the current one")
    func bareNameLeadsItsFamily() {
        let ordered = ClaudeModelRank.ordered(["claude-opus-4-6", "opus", "claude-opus-5"])

        #expect(ordered == ["opus", "claude-opus-5", "claude-opus-4-6"])
    }

    /// Read as a decimal, `5.10` is 5.1 and sorts below `5.9`. It is above it.
    @Test("versions are compared as numbers rather than as text")
    func versionsAreNumbers() {
        let ordered = ClaudeModelRank.ordered(["claude-opus-5-9", "claude-opus-5-10"])

        #expect(ordered == ["claude-opus-5-10", "claude-opus-5-9"])
    }

    @Test("a plain id comes before its window variants, widest first")
    func windowVariantsFollowThePlainID() {
        let ordered = ClaudeModelRank.ordered(
            ["claude-opus-5[200k]", "claude-opus-5[1m]", "claude-opus-5"]
        )

        #expect(ordered == ["claude-opus-5", "claude-opus-5[1m]", "claude-opus-5[200k]"])
    }

    @Test("an id naming no family Bloom knows goes last rather than above a paid-for model")
    func unknownIDsGoLast() {
        let ordered = ClaudeModelRank.ordered(["haiku", "something-else", "opus"])

        #expect(ordered == ["opus", "haiku", "something-else"])
    }

    @Test("two ids it cannot tell apart keep the order they arrived in")
    func stable() {
        let ordered = ClaudeModelRank.ordered(["first-unknown", "second-unknown"])

        #expect(ordered == ["first-unknown", "second-unknown"])
    }

    /// A number that is part of a project's name is not a version of the model.
    @Test("only the digits after the family's own word are read as a version")
    func versionIsReadAfterTheFamily() {
        #expect(ClaudeModelRank.key("bloom-4-opus").namesVersion == false)
        #expect(ClaudeModelRank.key("claude-opus-5").version == .init(major: 5, minor: 0))
    }

    @Test("an empty list is an empty list")
    func empty() {
        #expect(ClaudeModelRank.ordered([]).isEmpty)
    }

    /// The bare family name is the CLI's own word for the current model of that family, so it
    /// stays above every id that names a version, and a newer point release sits above an older
    /// one. `fable` is Fable 5.1 today and was Fable 5 last week, which is the whole reason the
    /// menu offers the alias rather than a version.
    @Test func aPointReleaseSitsUnderTheAliasAndOverTheReleaseBeforeIt() {
        let ordered = ClaudeModelRank.ordered(["claude-fable-5", "opus", "claude-fable-5-1", "fable"])

        #expect(ordered == ["fable", "claude-fable-5-1", "claude-fable-5", "opus"])
    }
}
