import Foundation
import Testing
@testable import BloomCore

/// The whole crossing, in the order it happens, because the bug was only ever visible end to end.
///
/// Files were dragged into the create sheet, "investigate this problem" was typed, Create was
/// pressed, and the agent answered that the message named no problem. Every step on its own looked
/// right: the files were staged, they were moved into the worktree, and the sentence went out. The
/// sheet was handing over the draft with its attachments already stripped, so the two halves of an
/// attachment, the file in the worktree and its path in the sentence, came apart between them.
@Suite("Attachments staged before the worktree existed", .scratchDirectory)
struct WorkspaceStartAttachmentsTests {
    private let file = ".bloom/attachments/9JVKW4/shot.png"

    /// The draft as the sheet holds it: words, and a file written in at the caret.
    private var draft: String {
        AttachmentDraft.inserting(file, into: "investigate this problem", at: 24).text
    }

    /// Lays a staged draft out the way `AttachmentStaging` does, and answers with its root.
    private func staging(holding paths: [String]) throws -> String {
        let root = TestScratch.unique("draft")
        for path in paths {
            let full = (root as NSString).appendingPathComponent(path)
            try FileManager.default.createDirectory(
                atPath: (full as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try Data("png".utf8).write(to: URL(filePath: full))
        }
        return root
    }

    private func worktree() throws -> String {
        let path = TestScratch.unique("worktree")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test("the file is in the worktree AND named in the first prompt")
    func fileCrossesAndIsNamed() throws {
        let staged = [file]
        let from = try staging(holding: staged)
        let into = try worktree()

        // The sheet's step. Handing over `spoken` here is the bug, and it is invisible until the
        // last assertion of this test.
        let handedOver = WorkspaceStartAttachments.handover(
            isChatWorkspace: true, draft: draft, name: ""
        )

        // The workspace is still named after what was asked for, not after an id folder.
        #expect(WorkspaceStartAttachments.spoken(handedOver, staged: staged)
            == "investigate this problem")

        let arrived = WorkspaceStartAttachments.adopt(staged, from: from, into: into)
        #expect(arrived == Set(staged))
        #expect(FileManager.default.fileExists(
            atPath: (into as NSString).appendingPathComponent(file)
        ))

        let opening = WorkspaceStartAttachments.opening(
            handedOver, staged: staged, arrived: arrived, isChatWorkspace: true
        )
        #expect(opening == "investigate this problem `\(file)`")
    }

    /// The other half of the same handover: everything that names the workspace reads `spoken`,
    /// and it must not see the file either.
    @Test("the id folder never reaches the name or the branch")
    func nameNeverSeesTheFile() {
        let handedOver = WorkspaceStartAttachments.handover(
            isChatWorkspace: true, draft: draft, name: ""
        )
        let spoken = WorkspaceStartAttachments.spoken(handedOver, staged: [file])
        #expect(!spoken.contains("9JVKW4"))
        #expect(Git.title(from: spoken) == "Investigate this problem")
    }

    /// A file that could not be moved is taken out of the sentence rather than named as a path to
    /// nothing, and the words on either side of it close up.
    @Test("a file that did not arrive is taken out of the sentence")
    func deadPathIsRemoved() throws {
        let staged = [file]
        let into = try worktree()
        // A staging root with nothing in it: the file was moved or deleted after being attached.
        let arrived = WorkspaceStartAttachments.adopt(
            staged, from: TestScratch.unique("empty"), into: into
        )
        #expect(arrived.isEmpty)

        let handedOver = WorkspaceStartAttachments.handover(
            isChatWorkspace: true, draft: draft, name: ""
        )
        let opening = WorkspaceStartAttachments.opening(
            handedOver, staged: staged, arrived: arrived, isChatWorkspace: true
        )
        #expect(opening == "investigate this problem")
    }

    /// Nothing staged is the ordinary case, and the sentence goes out untouched.
    @Test("a draft with no attachments is handed over as it was written")
    func plainDraftIsUntouched() {
        let opening = WorkspaceStartAttachments.opening(
            "investigate this problem", staged: [], arrived: [], isChatWorkspace: true
        )
        #expect(opening == "investigate this problem")
    }

    /// Terminal mode hands over the name field, sends no turn, and still carries the files: the
    /// shell it opens is standing in the worktree they were written for.
    @Test("a terminal workspace carries the files and sends nothing")
    func terminalCarriesButSendsNothing() throws {
        let staged = [file]
        let from = try staging(holding: staged)
        let into = try worktree()

        let handedOver = WorkspaceStartAttachments.handover(
            isChatWorkspace: false, draft: draft, name: "  spacing  "
        )
        #expect(handedOver == "spacing")

        let arrived = WorkspaceStartAttachments.adopt(staged, from: from, into: into)
        #expect(FileManager.default.fileExists(
            atPath: (into as NSString).appendingPathComponent(file)
        ))
        #expect(WorkspaceStartAttachments.opening(
            handedOver, staged: staged, arrived: arrived, isChatWorkspace: false
        ) == nil)
    }

    /// Git may not report what Bloom wrote into somebody's checkout. The move is the one route
    /// into the attachments folder that does not go through `AttachmentFiles.prepare`, so it has
    /// to lay the shield down itself.
    @Test("the attachments folder arrives shielded from git")
    func adoptShieldsTheFolder() throws {
        let staged = [file]
        let from = try staging(holding: staged)
        let into = try worktree()

        WorkspaceStartAttachments.adopt(staged, from: from, into: into)

        let ignore = (into as NSString)
            .appendingPathComponent(WorktreeScratch.attachments + "/.gitignore")
        #expect(FileManager.default.fileExists(atPath: ignore))
    }
}
