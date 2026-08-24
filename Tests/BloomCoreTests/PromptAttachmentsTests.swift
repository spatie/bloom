import Testing
@testable import BloomCore

/// Where a file the owner attached to a prompt gets written, and under what name.
///
/// This is a path-safety policy for files written into somebody's own checkout, and it lived in a
/// view with its reasoning in a comment. The `..` case in particular is the kind of claim that
/// wants a test: a name that survives as `..` is a name that means "the directory above".
@Suite("Naming an attached file")
struct PromptAttachmentsTests {
    // MARK: - The name

    /// The name is the one part of an attachment the owner recognises, so everything that is not
    /// actively dangerous survives.
    @Test("an ordinary name is left exactly as it is")
    func ordinaryNamesSurvive() {
        #expect(PromptAttachments.safeFilename("Screenshot 2026-08-24.png") == "Screenshot 2026-08-24.png")
        #expect(PromptAttachments.safeFilename("café ünïcode.txt") == "café ünïcode.txt")
        #expect(PromptAttachments.safeFilename("report (final) v2.pdf") == "report (final) v2.pdf")
    }

    /// A slash would silently put the file somewhere else entirely.
    @Test("a separator cannot make the name mean another directory")
    func separatorsCannotEscape() {
        #expect(!PromptAttachments.safeFilename("a/b/c.png").contains("/"))
        #expect(PromptAttachments.safeFilename("a/b/c.png") == "a-b-c.png")
        // Colon is the separator in the other direction: Finder shows it as a slash.
        #expect(!PromptAttachments.safeFilename("Volumes:disk:file.txt").contains(":"))
    }

    /// The claim the comment makes, checked. One pass over a name of nothing but dots leaves
    /// another dot in front, which is why every leading dot goes rather than the first.
    @Test("no name comes out as a dot, a double dot, or hidden")
    func dotsCannotSurvive() {
        #expect(PromptAttachments.safeFilename("..") == "attachment")
        #expect(PromptAttachments.safeFilename(".") == "attachment")
        #expect(PromptAttachments.safeFilename("....") == "attachment")
        // `..` surviving in the middle is harmless and is not what the rule is for: the
        // separators are gone, so this is one file with an odd name rather than a way up a
        // directory. What must never survive is a name that IS `..`, or one that starts with a
        // dot and hides itself from the person who came looking for it in Finder.
        #expect(PromptAttachments.safeFilename("../../etc/passwd") == "-..-etc-passwd")
        #expect(PromptAttachments.safeFilename(".env") == "env")
        for name in ["..", ".", "....", "../..", "./.", ".hidden"] {
            #expect(!PromptAttachments.safeFilename(name).hasPrefix("."))
        }
    }

    /// A name that is nothing once it is cleaned still has to be a name.
    @Test("a name that cleans away to nothing gets one")
    func emptyNamesGetAName() {
        #expect(PromptAttachments.safeFilename("") == "attachment")
        #expect(PromptAttachments.safeFilename("   ") == "attachment")
        #expect(PromptAttachments.safeFilename("\n\t ") == "attachment")
        #expect(!PromptAttachments.safeFilename("///").isEmpty)
    }

    // MARK: - Where it goes

    /// Inside the worktree, under Bloom's own corner of it, because the agent has to be able to
    /// read it without being asked for permission Bloom cannot answer.
    @Test("a copy lands under Bloom's scratch folder, keyed by its id")
    func destinationsAreInsideTheScratchFolder() {
        let path = PromptAttachments.destination(filename: "notes.md", id: "aB3xY9")
        #expect(path == "\(WorktreeScratch.attachments)/aB3xY9/notes.md")
        #expect(path.hasPrefix(WorktreeScratch.attachments))
    }

    /// The whole reason `safeFilename` exists: the destination is built by interpolation, so a
    /// name that carried a separator would build a path pointing outside the folder.
    @Test("a hostile name cannot climb out of the folder it is written into")
    func destinationsCannotEscape() {
        for hostile in ["../../../../etc/passwd", "..", "a/../../b", ".ssh/authorized_keys"] {
            let path = PromptAttachments.destination(filename: hostile, id: "aB3xY9")
            #expect(path.hasPrefix("\(WorktreeScratch.attachments)/aB3xY9/"))
            // The property that matters is the depth, not the absence of dots: a name keeping
            // `..` between two dashes is one file with an odd name, and a name keeping a
            // separator would be a file somewhere else entirely.
            #expect(path.components(separatedBy: "/").count
                == WorktreeScratch.attachments.components(separatedBy: "/").count + 2)
        }
    }

    // MARK: - The id

    /// Six characters, read in full in the path chip and in the prompt the agent is handed, so a
    /// UUID there would be thirty six characters of noise in both places.
    @Test("an id is six characters of an alphabet a path and a URL both accept")
    func idsAreShortAndSafe() {
        let allowed = Set("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        for _ in 0..<200 {
            let id = PromptAttachments.newShortID()
            #expect(id.count == 6)
            #expect(id.allSatisfy(allowed.contains))
            #expect(PromptAttachments.safeFilename(id) == id)
        }
    }

    /// Two attachments in one worktree colliding is not something that should happen.
    @Test("ids do not repeat in any quantity anybody attaches")
    func idsDoNotCollide() {
        let ids = Set((0..<500).map { _ in PromptAttachments.newShortID() })
        #expect(ids.count == 500)
    }
}
