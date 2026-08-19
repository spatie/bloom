import Testing
import Foundation
@testable import BloomCore

/// The attachment trailer is the one place in Bloom where prose is parsed, and it is parsed out of
/// a message the user wrote. Getting it wrong does not produce a wrong chip, it produces a sentence
/// missing from somebody's own transcript, so the shape it accepts is pinned down here from both
/// ends: everything `compose` writes has to come back, and everything else has to be left alone.
@Suite("Attachment trailer")
struct AttachmentTrailerTests {
    // MARK: - What the agent receives

    @Test("one file reads as one file")
    func composesSingular() {
        let text = AttachmentTrailer.compose(text: "look at this", paths: [".bloom/a/IMG.jpeg"])

        #expect(text == "look at this\n\nAttached file:\n- .bloom/a/IMG.jpeg")
    }

    @Test("several are listed under a plural header")
    func composesPlural() {
        let text = AttachmentTrailer.compose(text: "  compare  ", paths: ["a.png", "b.png"])

        #expect(text == "compare\n\nAttached files:\n- a.png\n- b.png")
    }

    @Test("no attachments changes nothing at all")
    func composesNothing() {
        #expect(AttachmentTrailer.compose(text: "hello", paths: []) == "hello")
        #expect(AttachmentTrailer.compose(text: "", paths: []).isEmpty)
    }

    @Test("attachments alone are still a prompt")
    func composesWithoutABody() {
        #expect(AttachmentTrailer.compose(text: "", paths: ["a.png"]) == "Attached file:\n- a.png")
        #expect(AttachmentTrailer.compose(text: "   \n ", paths: ["a.png"]) == "Attached file:\n- a.png")
    }

    // MARK: - What the transcript draws

    @Test("a composed prompt comes back as what was typed and what was attached")
    func roundTrips() {
        let cases: [(String, [String])] = [
            ("look at this", [".bloom/attachments/9JVKW4/IMG_4395.jpeg"]),
            ("compare these", ["a.png", "b.png", "Sources/Foo.swift"]),
            ("", ["only.png"]),
            ("two\nlines of it", ["one.png"]),
            ("a line, then a blank one\n\nand more", ["one.png", "two.png"]),
        ]

        for (body, paths) in cases {
            let split = AttachmentTrailer.split(AttachmentTrailer.compose(text: body, paths: paths))
            #expect(split.body == body)
            #expect(split.paths == paths)
        }
    }

    @Test("a prompt with no trailer is returned whole")
    func leavesOrdinaryTextAlone() {
        let split = AttachmentTrailer.split("what is in this file?")

        #expect(split.body == "what is in this file?")
        #expect(split.paths.isEmpty)
    }

    @Test("an empty prompt is not a trailer")
    func leavesEmptyTextAlone() {
        #expect(AttachmentTrailer.split("").paths.isEmpty)
        #expect(AttachmentTrailer.split("").body.isEmpty)
    }

    @Test("a header that disagrees with the count is prose")
    func refusesAMismatchedHeader() {
        let one = AttachmentTrailer.split("hi\n\nAttached files:\n- a.png")
        #expect(one.paths.isEmpty)
        #expect(one.body == "hi\n\nAttached files:\n- a.png")

        let many = AttachmentTrailer.split("hi\n\nAttached file:\n- a.png\n- b.png")
        #expect(many.paths.isEmpty)
    }

    @Test("a header with nothing under it is prose")
    func refusesAnEmptyList() {
        #expect(AttachmentTrailer.split("Attached file:").paths.isEmpty)
        #expect(AttachmentTrailer.split("hi\n\nAttached files:").paths.isEmpty)
    }

    @Test("anything after the list means the list was not the trailer")
    func refusesTrailingProse() {
        let split = AttachmentTrailer.split("hi\n\nAttached file:\n- a.png\nwhat do you think?")

        #expect(split.paths.isEmpty)
        #expect(split.body == "hi\n\nAttached file:\n- a.png\nwhat do you think?")
    }

    @Test("a list item that is not a bare path is prose")
    func refusesDecoratedItems() {
        #expect(AttachmentTrailer.split("Attached file:\n-a.png").paths.isEmpty)
        #expect(AttachmentTrailer.split("Attached file:\n- ").paths.isEmpty)
        #expect(AttachmentTrailer.split("Attached file:\n-  a.png").paths.isEmpty)
        #expect(AttachmentTrailer.split("Attached file:\n- a.png ").paths.isEmpty)
        #expect(AttachmentTrailer.split("Attached files:\n- a.png\n\n- b.png").paths.isEmpty)
    }

    @Test("the trailer is separated from the body by exactly one blank line")
    func refusesTheWrongSeparator() {
        #expect(AttachmentTrailer.split("hi\nAttached file:\n- a.png").paths.isEmpty)
        #expect(AttachmentTrailer.split("hi\n\n\nAttached file:\n- a.png").paths.isEmpty)
    }

    @Test("only the last header starts the trailer, so a quoted one stays in the body")
    func takesTheLastHeader() {
        let sent = AttachmentTrailer.compose(
            text: "you said\n\nAttached file:\n- old.png\n\nbut look at this",
            paths: ["new.png"]
        )
        let split = AttachmentTrailer.split(sent)

        #expect(split.paths == ["new.png"])
        #expect(split.body == "you said\n\nAttached file:\n- old.png\n\nbut look at this")
    }

    @Test("a path with spaces in its name survives, because macOS names look like that")
    func keepsNamesWithSpaces() {
        let path = ".bloom/attachments/aB3xY9/CleanShot 2026-08-19 at 00.04.38@2x.jpg"
        let split = AttachmentTrailer.split(AttachmentTrailer.compose(text: "this", paths: [path]))

        #expect(split.paths == [path])
    }
}
