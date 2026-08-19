import Testing
@testable import BloomCore

/// Folding reindentation out of a parsed patch, which is what the inspector's "ignore whitespace"
/// toggle does without spawning a second `git diff -w`.
@Suite("Ignoring whitespace in a diff")
struct DiffWhitespaceTests {
    private func diff(_ patch: String) -> FileDiff {
        let parsed = DiffParser.parse(patch)
        guard let file = parsed.first else {
            Issue.record("the patch did not parse into a file")
            return FileDiff()
        }
        return file
    }

    private func patch(_ body: String) -> String {
        """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        \(body)
        """
    }

    @Test("a line that only gained indentation folds back into context")
    func reindentationFolds() {
        let folded = diff(patch("""
        @@ -1,3 +1,3 @@
         before
        -let x = 1
        +    let x = 1
         after
        """)).ignoringWhitespace()

        #expect(folded.hunks.isEmpty)
        #expect(folded.additions == 0)
        #expect(folded.deletions == 0)
    }

    @Test("the surviving line is the new text, and both gutters keep their numbers")
    func foldedLineKeepsBothNumbers() {
        let folded = diff(patch("""
        @@ -1,3 +1,4 @@
         before
        -let x = 1
        +    let x = 1
         after
        +added
        """)).ignoringWhitespace()

        let lines = folded.hunks.flatMap(\.lines)
        guard let survivor = lines.first(where: { $0.text.contains("let x") }) else {
            Issue.record("the reindented line was dropped entirely")
            return
        }
        #expect(survivor.kind == .context)
        #expect(survivor.text == "    let x = 1")
        #expect(survivor.oldNumber == 2)
        #expect(survivor.newNumber == 2)
    }

    @Test("a real edit is left exactly as it was")
    func realEditSurvives() {
        let original = diff(patch("""
        @@ -1,3 +1,3 @@
         before
        -let x = 1
        +let x = 2
         after
        """))
        let folded = original.ignoringWhitespace()

        #expect(folded.hunks == original.hunks)
        #expect(folded.additions == 1)
        #expect(folded.deletions == 1)
    }

    @Test("a block whose two sides do not pair up one for one is left alone")
    func unevenBlockIsLeftAlone() {
        let folded = diff(patch("""
        @@ -1,3 +1,4 @@
         before
        -let x = 1
        +    let x = 1
        +    let y = 2
         after
        """)).ignoringWhitespace()

        #expect(folded.additions == 2)
        #expect(folded.deletions == 1)
    }

    @Test("an addition with nothing removed beside it is not whitespace")
    func pureAdditionSurvives() {
        let folded = diff(patch("""
        @@ -1,2 +1,3 @@
         before
        +added
         after
        """)).ignoringWhitespace()

        #expect(folded.additions == 1)
        #expect(folded.deletions == 0)
    }

    @Test("a hunk left with nothing but context is dropped, not shown empty")
    func emptyHunkIsDropped() {
        let folded = diff(patch("""
        @@ -1,3 +1,3 @@
         before
        -let x = 1
        +	let x = 1
         after
        @@ -10,3 +10,3 @@
         before
        -let y = 1
        +let y = 2
         after
        """)).ignoringWhitespace()

        #expect(folded.hunks.count == 1)
        #expect(folded.hunks.first?.newStart == 10)
    }

    @Test("a tab and four spaces are the same amount of nothing")
    func tabsAndSpacesBothFold() {
        let folded = diff(patch("""
        @@ -1,3 +1,3 @@
         before
        -\tlet x = 1
        +    let x = 1
         after
        """)).ignoringWhitespace()

        #expect(folded.hunks.isEmpty)
    }

    @Test("whitespace inside a line counts too, so a respacing folds")
    func interiorWhitespaceFolds() {
        let folded = diff(patch("""
        @@ -1,3 +1,3 @@
         before
        -let x=1
        +let x = 1
         after
        """)).ignoringWhitespace()

        #expect(folded.hunks.isEmpty)
    }

    @Test("a diff with no hunks comes back with no hunks rather than crashing")
    func emptyDiff() {
        let folded = FileDiff(newPath: "a.swift").ignoringWhitespace()
        #expect(folded.hunks.isEmpty)
        #expect(folded.additions == 0)
    }
}
