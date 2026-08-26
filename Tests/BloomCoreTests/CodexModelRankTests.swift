import Testing
@testable import BloomCore

@Suite("Ordering the Codex models")
struct CodexModelRankTests {
    private func model(_ id: String, isDefault: Bool = false) -> CodexModel {
        CodexModel(id: id, displayName: id, isDefault: isDefault)
    }

    @Test("a newer version comes first")
    func newerFirst() {
        let ordered = CodexModelRank.ordered([
            model("gpt-5.4"), model("gpt-5.6"), model("gpt-5.5"),
        ])
        #expect(ordered.map(\.id) == ["gpt-5.6", "gpt-5.5", "gpt-5.4"])
    }

    /// The reason `version(of:)` parses rather than compares text: as a string, "gpt-5.10" sorts
    /// below "gpt-5.9", and the string answer is the wrong one.
    @Test("a two-digit minor is a number, not a string")
    func twoDigitMinor() {
        let ordered = CodexModelRank.ordered([model("gpt-5.9"), model("gpt-5.10")])
        #expect(ordered.map(\.id) == ["gpt-5.10", "gpt-5.9"])
    }

    @Test("a cut-down model sits under the full one of its own version")
    func reducedBelow() {
        let ordered = CodexModelRank.ordered([
            model("gpt-5.4-mini"), model("gpt-5.4"), model("gpt-5.3-codex-spark"),
        ])
        #expect(ordered.map(\.id) == ["gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex-spark"])
    }

    /// A newer cut-down model still beats an older full one, because the version rule is the first
    /// rule. This is the case that says the two rules are ordered rather than combined.
    @Test("version decides before size does")
    func versionBeatsSize() {
        let ordered = CodexModelRank.ordered([model("gpt-5.4"), model("gpt-5.6-mini")])
        #expect(ordered.map(\.id) == ["gpt-5.6-mini", "gpt-5.4"])
    }

    /// Sol, Terra and Luna carry nothing that ranks them, so the vendor's order is kept rather
    /// than a rank being invented.
    @Test("variants of one version keep the order they arrived in")
    func stableAmongEquals() {
        let ordered = CodexModelRank.ordered([
            model("gpt-5.6-sol"), model("gpt-5.6-terra"), model("gpt-5.6-luna"),
        ])
        #expect(ordered.map(\.id) == ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"])
    }

    /// The rule that changed: the account's default used to be moved to the top, which made the
    /// same list come out in two orders on two machines.
    @Test("the account default does not jump the queue")
    func defaultStaysPut() {
        let ordered = CodexModelRank.ordered([
            model("gpt-5.6"), model("gpt-5.4", isDefault: true),
        ])
        #expect(ordered.map(\.id) == ["gpt-5.6", "gpt-5.4"])
    }

    @Test("an id with no version at all falls to the bottom rather than the top")
    func unversionedLast() {
        let ordered = CodexModelRank.ordered([model("codex-preview"), model("gpt-5.4")])
        #expect(ordered.map(\.id) == ["gpt-5.4", "codex-preview"])
    }

    /// `isReduced` matches whole words, so a name that merely contains the letters is not demoted.
    @Test("a word inside another word is not a size")
    func wordBoundary() {
        #expect(CodexModelRank.isReduced("gpt-5.4-mini"))
        #expect(!CodexModelRank.isReduced("gpt-5.4-minimal-risk"))
        #expect(!CodexModelRank.isReduced("gpt-5.4-sparkle"))
    }
}
