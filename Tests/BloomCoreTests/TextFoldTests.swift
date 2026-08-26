import Testing
@testable import BloomCore

/// The control under a folded block of output.
///
/// Four views wrote four sentences for it and every one of them was one way, so a dump unfolded
/// once could not be folded again. The test that matters is the first: there is a second
/// direction, and it says something.
@Suite("What the fold under a block of output says")
struct TextFoldTests {
    @Test("it folds back, which is the whole point of it")
    func bothDirections() {
        #expect(TextFold.title(isExpanded: false) == "Show all")
        #expect(TextFold.title(isExpanded: true) == "Show less")
    }

    /// The count is the caller's to offer. A code fence has already split its lines and knows;
    /// a tool result is a `String` and would have to walk megabytes to find out.
    @Test("a caller that has counted the lines says so, and one that has not is not made to")
    func lineCount() {
        #expect(TextFold.title(isExpanded: false, lines: 812) == "Show all 812 lines")
        #expect(TextFold.title(isExpanded: false, lines: nil) == "Show all")
    }

    /// "Show all 1 lines" was reachable in the fence, which caps at 2,000 lines and could in
    /// principle be handed a block whose count is one.
    @Test("one line is a line")
    func singular() {
        #expect(TextFold.title(isExpanded: false, lines: 1) == "Show all 1 line")
    }

    /// The count is only ever an aside. Folding back says the same thing whether or not the
    /// caller counted, because "Show less 812 lines" is not a sentence.
    @Test("the way back never carries the count")
    func expandedIgnoresCount() {
        #expect(TextFold.title(isExpanded: true, lines: 812) == "Show less")
    }
}
