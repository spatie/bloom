import Foundation
import Testing
@testable import BloomCore

/// A count and its noun, which is the pair four views got wrong in two different ways: a bare
/// interpolation with no thousands separator, and a hardcoded plural that reads "1 lines" on the
/// one value nobody tries.
@Suite("Counted")
struct CountedTests {
    @Test("one is singular and everything else is not")
    func agreement() {
        #expect(Counted.of(1, "line") == "1 line")
        #expect(Counted.of(0, "line") == "0 lines")
        #expect(Counted.of(2, "line") == "2 lines")
    }

    @Test("a noun an s does not pluralise says so itself")
    func irregular() {
        #expect(Counted.of(1, "match", plural: "matches") == "1 match")
        #expect(Counted.of(3, "match", plural: "matches") == "3 matches")
    }

    /// The half that was silently dropped every time this was written again at a call site: a
    /// four figure count read "1200 lines" rather than the reader's own grouping.
    @Test("the number is formatted for the reader, not interpolated")
    func grouping() {
        let counted = Counted.of(1_200, "line")
        #expect(counted == "\(1_200.formatted()) lines")
        #expect(counted != "1200 lines" || 1_200.formatted() == "1200")
    }

    @Test("the noun can be taken on its own, for a sentence that writes its own number")
    func wordAlone() {
        #expect(Counted.word(1, "comment") == "comment")
        #expect(Counted.word(4, "comment") == "comments")
    }

    /// `ArchiveDeletion.count` was this function under another name and is now a call to it, so
    /// the archive's wording and everything else in the window cannot drift apart again.
    @Test("the archive's own counter is the same counter")
    func archiveDelegates() {
        #expect(ArchiveDeletion.count(1, "chat") == Counted.of(1, "chat"))
        #expect(ArchiveDeletion.count(1_000, "workspace") == Counted.of(1_000, "workspace"))
    }
}
