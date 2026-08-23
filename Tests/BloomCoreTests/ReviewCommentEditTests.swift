import Testing
@testable import BloomCore

/// Editing a pending review comment in place. The three things a view must not decide on its own:
/// what reaches the store, what an emptied field means, and whether a write happens at all.
@Suite("Review comment edit")
struct ReviewCommentEditTests {
    @Test("saves the trimmed text")
    func savesTrimmed() {
        #expect(
            ReviewCommentEdit.outcome(typed: "  this is wrong\n", replacing: "old")
                == .save("this is wrong")
        )
    }

    @Test("keeps the line breaks inside a multi-line comment")
    func keepsInteriorBreaks() {
        let typed = "\n first line\nsecond line\n\n"

        #expect(
            ReviewCommentEdit.outcome(typed: typed, replacing: "old")
                == .save("first line\nsecond line")
        )
    }

    @Test("refuses an empty edit rather than reading it as a deletion", arguments: [
        "", "   ", "\n", " \t\n ",
    ])
    func refusesEmpty(typed: String) {
        #expect(ReviewCommentEdit.outcome(typed: typed, replacing: "old") == .refused)
        #expect(!ReviewCommentEdit.canSubmit(typed))
    }

    @Test("writes nothing when the text says what the comment already says")
    func unchanged() {
        #expect(ReviewCommentEdit.outcome(typed: "same", replacing: "same") == .unchanged)
        // Whitespace the trim removes is not a change either, so an editor opened and closed
        // after a stray space does not invalidate every list reading the comments.
        #expect(ReviewCommentEdit.outcome(typed: " same \n", replacing: "same") == .unchanged)
    }

    @Test("offers the confirm control for anything with a character in it")
    func canSubmit() {
        #expect(ReviewCommentEdit.canSubmit("a"))
        #expect(ReviewCommentEdit.canSubmit("  a  "))
        #expect(ReviewCommentEdit.canSubmit("line\nline"))
    }

    /// A body that arrived with edges, which nothing writes today but a restored row or an older
    /// build could hold: the edit is worth making, because the trimmed text is not what is stored.
    @Test("tidies a stored body that carries whitespace")
    func tidiesStoredEdges() {
        #expect(ReviewCommentEdit.outcome(typed: "note", replacing: "note ") == .save("note"))
    }
}
