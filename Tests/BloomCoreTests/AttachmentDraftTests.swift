import Testing
import Foundation
@testable import BloomCore

/// The draft is the only record that a file is attached, so the two directions have to agree for
/// every draft there is. `parse(text).text == text` is the whole contract, and the table below is
/// driven through it in both directions.
@Suite("Attachment draft")
struct AttachmentDraftTests {
    static let copy = ".bloom/attachments/9JVKW4/shot.png"
    static let spaced = ".bloom/attachments/aB3xZ9/Pasted 2026-08-20 at 22.29.20.png"
    static let inWorktree = "Sources/Bloom/Views/Center/ComposerView.swift"

    /// Every draft worth having an opinion about, with the files the composer knows it copied.
    static let drafts: [(draft: String, known: [String], paths: [String])] = [
        ("", [], []),
        ("no files here at all", [], []),
        ("have a look at `\(copy)` and fix the spacing", [], [copy]),
        ("`\(copy)`", [], [copy]),
        ("`\(copy)` what is this", [], [copy]),
        ("what is this `\(copy)`", [], [copy]),
        ("`\(spaced)` reads its own spaces", [], [spaced]),
        (
            "compare `\(copy)` with `\(spaced)` please",
            [],
            [copy, spaced]
        ),
        ("/review `\(copy)` this one", [], [copy]),
        ("this one `\(inWorktree)` is already here", [inWorktree], [inWorktree]),
        ("run `git status` first", [], []),
        ("`.bloom/attachments/9JVKW4`", [], []),
        ("`.bloom/attachments/`", [], []),
        ("an unclosed ` backtick", [], []),
        ("two `spans` of `words`", [], []),
        ("a `\(copy)` then `code` then `\(spaced)`", [], [copy, spaced]),
    ]

    @Test("Every draft round trips through parse and back")
    func roundTrip() {
        for row in Self.drafts {
            let parsed = AttachmentDraft.parse(row.draft, paths: row.known)
            #expect(parsed.text == row.draft, "round trip changed: \(row.draft)")
            #expect(parsed.paths == row.paths, "wrong files in: \(row.draft)")
        }
    }

    @Test("A file already in the worktree is only a chip once the composer says so")
    func knownPathsOnly() {
        let draft = "this one `\(Self.inWorktree)` is already here"
        #expect(AttachmentDraft.parse(draft).paths.isEmpty)
        #expect(AttachmentDraft.parse(draft, paths: [Self.inWorktree]).paths == [Self.inWorktree])
    }

    @Test("A file in Bloom's own folder is recognised from the text alone")
    func copiesNeedNoTelling() {
        // The pull request instructions, in both of the places they can be.
        #expect(AttachmentDraft.isAttachment(".bloom/scratch/pr-instructions.md"))
        #expect(AttachmentDraft.isAttachment(".bloom/pr-instructions.md"))
        // Somebody else's file, which is only a chip when the composer vouches for it.
        #expect(!AttachmentDraft.isAttachment("Sources/Bloom/Views/Center/ComposerView.swift"))
        #expect(!AttachmentDraft.isAttachment(".bloom/"))
        #expect(AttachmentDraft.isAttachment(Self.copy))
        #expect(AttachmentDraft.isAttachment(Self.spaced))
        #expect(!AttachmentDraft.isAttachment(".bloom/attachments/9JVKW4"))
        #expect(!AttachmentDraft.isAttachment(".bloom/attachments/9JVKW4/"))
        #expect(!AttachmentDraft.isAttachment(".bloom/attachments//shot.png"))
        #expect(!AttachmentDraft.isAttachment("git status"))
        #expect(!AttachmentDraft.isAttachment(""))
        #expect(!AttachmentDraft.isAttachment(".bloom/attachments/9J\nVKW4/a.png"))
    }

    // MARK: - Writing one in

    @Test("A file lands where the caret is, spaced into the sentence")
    func insertsAtCaret() {
        let draft = "have a look at and fix the spacing"
        let caret = ("have a look at " as NSString).length
        let result = AttachmentDraft.inserting(Self.copy, into: draft, at: caret)

        #expect(result.text == "have a look at `\(Self.copy)` and fix the spacing")
        #expect(result.caret == caret + ("`\(Self.copy)` " as NSString).length)
        #expect(AttachmentDraft.parse(result.text).paths == [Self.copy])
    }

    @Test("A space is added on a side that has none, and never doubled")
    func spacing() {
        #expect(
            AttachmentDraft.inserting(Self.copy, into: "look at", at: 7).text
                == "look at `\(Self.copy)` "
        )
        #expect(
            AttachmentDraft.inserting(Self.copy, into: "look at ", at: 8).text
                == "look at `\(Self.copy)` "
        )
        #expect(
            AttachmentDraft.inserting(Self.copy, into: "", at: 0).text == "`\(Self.copy)` "
        )
        #expect(
            AttachmentDraft.inserting(Self.copy, into: "ab", at: 1).text
                == "a `\(Self.copy)` b"
        )
        // Onto the start of a line of its own.
        #expect(
            AttachmentDraft.inserting(Self.copy, into: "one\ntwo", at: 4).text
                == "one\n`\(Self.copy)` two"
        )
    }

    @Test("An offset outside the draft is clamped rather than trapped")
    func clampsOffset() {
        #expect(AttachmentDraft.inserting(Self.copy, into: "hi", at: 99).text == "hi `\(Self.copy)` ")
        #expect(AttachmentDraft.inserting(Self.copy, into: "hi", at: -3).text == "`\(Self.copy)` hi")
    }

    @Test("Several files dropped at one point stay in the order they were handed over")
    func insertsSeveral() {
        let result = AttachmentDraft.inserting(
            [Self.copy, Self.spaced], into: "compare and say", at: 8
        )
        #expect(result.text == "compare `\(Self.copy)` `\(Self.spaced)` and say")
        #expect(AttachmentDraft.parse(result.text).paths == [Self.copy, Self.spaced])
    }

    @Test("Two files in one prompt, one at each end")
    func bothEnds() {
        var draft = ""
        var caret = 0
        let opening = AttachmentDraft.inserting(Self.copy, into: draft, at: caret)
        draft = opening.text
        caret = opening.caret
        draft = (draft as NSString).replacingCharacters(
            in: NSRange(location: caret, length: 0), with: "and"
        )
        caret += 3
        let closing = AttachmentDraft.inserting(Self.spaced, into: draft, at: caret)

        #expect(closing.text == "`\(Self.copy)` and `\(Self.spaced)` ")
        #expect(AttachmentDraft.parse(closing.text).paths == [Self.copy, Self.spaced])
    }

    // MARK: - Taking one out

    @Test("A file that cannot be sent leaves the sentence closed up")
    func dropsOne() {
        let draft = "compare `\(Self.copy)` with `\(Self.spaced)` please"
        let kept = AttachmentDraft.parse(draft).keeping { $0 == Self.copy }
        #expect(kept == "compare `\(Self.copy)` with please")
    }

    @Test("A file at the start takes the space after it rather than leaving a gap")
    func dropsAtStart() {
        let draft = "`\(Self.copy)` what is this"
        #expect(AttachmentDraft.parse(draft).keeping { _ in false } == "what is this")
    }

    @Test("What the sentence says without its files")
    func withoutAttachments() {
        #expect(
            AttachmentDraft.withoutAttachments("have a look at `\(Self.copy)` and fix the spacing")
                == "have a look at and fix the spacing"
        )
        #expect(AttachmentDraft.withoutAttachments("`\(Self.copy)`").isEmpty)
        #expect(AttachmentDraft.withoutAttachments("run `git status`") == "run `git status`")
    }

    // MARK: - Sharing a draft with a slash command

    /// Both types claim to own parts of the same string, so the one thing that matters is that
    /// neither can see the other's: a command is the first token of the draft, and a file is
    /// always inside backticks, which a command name cannot contain.
    @Test("A slash command and a file in one draft leave each other alone")
    func withSlashCommand() {
        let draft = "/superpowers:requesting-code-review `\(Self.copy)` and this one too"

        let command = SlashCommandDraft.parse(draft)
        #expect(command.name == "superpowers:requesting-code-review")
        #expect(command.body == "`\(Self.copy)` and this one too")
        #expect(command.text == draft)

        // The composer parses attachments out of the body, which is what the editor is editing.
        let files = AttachmentDraft.parse(command.body)
        #expect(files.paths == [Self.copy])
        #expect(files.text == command.body)

        // And back the other way: putting an edited body back keeps the command.
        var rebuilt = command
        rebuilt.body = files.text
        #expect(rebuilt.text == draft)
    }

    @Test("A path is never mistaken for a command, and a command never for a path")
    func neitherEatsTheOther() {
        // A draft that is nothing but a file does not lead with a slash: it leads with a backtick.
        let draft = "`\(Self.copy)` "
        #expect(SlashCommandDraft.parse(draft).name == nil)

        // And a command with no body still round trips once a file is written into it.
        let inserted = AttachmentDraft.inserting(Self.copy, into: "", at: 0)
        var command = SlashCommandDraft(name: "review", body: inserted.text)
        #expect(command.text == "/review `\(Self.copy)` ")
        command.body = AttachmentDraft.parse(command.body).text
        #expect(command.text == "/review `\(Self.copy)` ")
    }

    // MARK: - Drafts that were saved before this existed

    @Test("Attachments held beside an old draft are written into it once")
    func migratesOldDrafts() {
        let draft = "have a look at this"
        let result = AttachmentDraft.inserting(
            [Self.copy], into: draft, at: (draft as NSString).length
        )
        #expect(result.text == "have a look at this `\(Self.copy)` ")
        #expect(AttachmentDraft.parse(result.text).paths == [Self.copy])
    }
}
