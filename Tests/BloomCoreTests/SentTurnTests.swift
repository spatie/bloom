import Testing
import Foundation
@testable import BloomCore

/// How a turn Bloom composed is cut up for the bubble that draws it.
///
/// The property that everything else rests on is the first one asserted: the segments joined back
/// together are the turn, byte for byte. A transcript is a record of what was sent, and a bubble
/// drawn from a string that differs from the one the agent read is a bubble that can quietly lie
/// about it. The old shape did lift the merge rules out of the text, which is what this replaced.
///
/// The rejections matter as much as the matches. A block is recognised byte for byte and only at
/// the head of a paragraph, so a person quoting a line of the merge rules in their own message
/// keeps their sentence.
@Suite("Sent turn")
struct SentTurnTests {
    // MARK: - What comes back is what went out

    @Test("the segments are the turn again", arguments: [
        "Merge #42.\n\n\(MergeInstructions.canonical)",
        "Open a pull request.\n\nFollow the instructions in `.bloom/scratch/pr-instructions.md`.",
        "Nothing injected here at all.",
        "",
    ])
    func segmentsRebuildTheTurn(turn: String) {
        #expect(SentTurn.segments(in: turn).map(\.text).joined() == turn)
    }

    @Test("a merge turn carrying a project's own words is still the turn again")
    func mergeWithProjectWordsRebuilds() {
        let turn = ProjectInstructions.turn(
            "Merge #42.", for: .merge, adding: .inline("We merge on Fridays only.")
        )
        #expect(SentTurn.segments(in: turn).map(\.text).joined() == turn)
    }

    // MARK: - The four kinds

    @Test("Bloom's merge rules are one chip")
    func mergeRulesBecomeAChip() {
        let turn = "Merge #42.\n\n\(MergeInstructions.canonical)"

        #expect(SentTurn.segments(in: turn) == [
            .text("Merge #42.\n\n"),
            .instructions(
                InjectedInstruction(title: SentTurn.mergeTitle, body: MergeInstructions.canonical)
            ),
        ])
    }

    /// The usual road for these two is a file, which the sentence names and `FileMention` finds.
    /// They reach the message only in a checkout that could not be written to, and that is exactly
    /// the turn whose reader would otherwise have no idea what the agent was handed.
    @Test("the pull request and conflict fallbacks are chips too")
    func writtenOutInstructionsBecomeChips() {
        let pullRequest = "Open a pull request.\n\n\(PullRequestInstructions.defaultMarkdown)"
        let conflicts = "Fix the conflicts.\n\n\(ConflictInstructions.defaultMarkdown)"

        #expect(SentTurn.segments(in: pullRequest).contains(
            .instructions(InjectedInstruction(
                title: SentTurn.pullRequestTitle, body: PullRequestInstructions.defaultMarkdown
            ))
        ))
        #expect(SentTurn.segments(in: conflicts).contains(
            .instructions(InjectedInstruction(
                title: SentTurn.conflictTitle, body: ConflictInstructions.defaultMarkdown
            ))
        ))
    }

    /// A turn an older Bloom sent is still in the database and still has to draw.
    @Test("a retired default is still recognised")
    func retiredDefaultsAreRecognised() throws {
        let retired = try #require(PullRequestInstructions.retiredDefaults.first)
        let turn = "Open a pull request.\n\n\(retired)"

        #expect(SentTurn.segments(in: turn).contains(
            .instructions(
                InjectedInstruction(title: SentTurn.pullRequestTitle, body: retired)
            )
        ))
    }

    /// The sentence saying a project has its own words stays as prose and the words themselves are
    /// the chip. That is the same shape the file case has, where a sentence names a file and the
    /// pill is the file: the reader is told what is attached, and then can look at it.
    @Test("a project's own words are a chip and the sentence in front of them is not")
    func projectWordsBecomeAChip() {
        let words = "We merge on Fridays only.\nAsk Freek first."
        let turn = ProjectInstructions.turn("Merge #42.", for: .merge, adding: .inline(words))
        let segments = SentTurn.segments(in: turn)

        #expect(segments.contains(
            .instructions(InjectedInstruction(title: SentTurn.projectTitle, body: words))
        ))
        #expect(SentTurn.withoutInstructions(turn).hasSuffix(
            ProjectInstructions.inlineLead(for: .merge)
        ))
    }

    @Test("both blocks of a merge turn are chips, in the order they were read in")
    func mergeCarriesTwoBlocks() {
        let turn = ProjectInstructions.turn(
            "Merge #42.", for: .merge, adding: .inline("We merge on Fridays only.")
        )
        let titles = SentTurn.segments(in: turn).compactMap { segment -> String? in
            guard case .instructions(let block) = segment else { return nil }
            return block.title
        }

        #expect(titles == [SentTurn.mergeTitle, SentTurn.projectTitle])
    }

    // MARK: - What is left alone

    @Test("a file named in the sentence is still a file")
    func filesAreStillFiles() {
        let turn = "Open a pull request.\n\nFollow the instructions in "
            + "`.bloom/scratch/pr-instructions.md`."

        #expect(SentTurn.segments(in: turn).contains(.file(".bloom/scratch/pr-instructions.md")))
    }

    /// A block is Bloom's only where Bloom put it, which is at the head of a paragraph. Quoted in
    /// the middle of somebody's sentence it is somebody's sentence.
    @Test("a quoted line of the rules stays part of the sentence")
    func quotedRulesStayText() throws {
        let quoted = try #require(MergeInstructions.canonical.split(separator: "\n").first)
        let turn = "Why did you not \(quoted) like I asked?"

        #expect(SentTurn.segments(in: turn) == [.text(turn)])
    }

    @Test("a message with nothing injected is one run of words")
    func ordinaryTurnIsOneRun() {
        let turn = "Have a look at the merge instructions I wrote down somewhere."
        #expect(SentTurn.segments(in: turn) == [.text(turn)])
    }

    // MARK: - The one line summary

    @Test("a summary drops the blocks and keeps the request")
    func summaryKeepsTheRequest() {
        let turn = "Merge #42.\n\n\(MergeInstructions.canonical)"
        #expect(SentTurn.withoutInstructions(turn) == "Merge #42.")
    }
}
