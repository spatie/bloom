import Foundation
import Testing
@testable import BloomCore

@Suite("Workspace lifecycle note")
struct WorkspaceLifecycleNoteTests {
    private func facts(
        branchKept: Bool = true, ranArchiveScript: Bool = false, hasSetupScript: Bool = false,
        keptFolder: String? = nil
    ) -> WorkspaceLifecycleNote.ArchiveFacts {
        WorkspaceLifecycleNote.ArchiveFacts(
            branch: "feature/x", branchKept: branchKept, ranArchiveScript: ranArchiveScript,
            hasSetupScript: hasSetupScript, keptFolder: keptFolder
        )
    }

    @Test("an archive that kept the branch says a restore runs the setup script again")
    func archivedWithSetup() {
        let note = WorkspaceLifecycleNote.archived(facts(ranArchiveScript: true, hasSetupScript: true))
        #expect(note.sentence.contains("removed after the archive script ran"))
        #expect(note.sentence.contains("branch feature/x was kept"))
        #expect(note.sentence.contains("runs the setup script again"))
    }

    @Test("without a setup script the restore sentence promises none")
    func archivedWithoutSetup() {
        let note = WorkspaceLifecycleNote.archived(facts())
        #expect(!note.sentence.contains("setup"))
        #expect(!note.sentence.contains("archive script"))
    }

    @Test("a deleted branch says nothing about restoring")
    func archivedBranchDeleted() {
        let note = WorkspaceLifecycleNote.archived(facts(branchKept: false, hasSetupScript: true))
        #expect(note.sentence.contains("branch feature/x was deleted"))
        #expect(!note.sentence.contains("Restoring"))
    }

    @Test("a kept folder says the worktree was not cleaned")
    func archivedFolderKept() {
        let note = WorkspaceLifecycleNote.archived(facts(ranArchiveScript: true, keptFolder: "/tmp/w"))
        #expect(note.sentence.contains("/tmp/w"))
        #expect(note.sentence.contains("archive script was skipped"))
        #expect(!note.sentence.contains("was removed"))
    }

    @Test("a restore says whether setup is running and where the worktree went")
    func restored() {
        let plain = WorkspaceLifecycleNote.restored(setupRuns: false)
        #expect(!plain.sentence.contains("setup"))

        let moved = WorkspaceLifecycleNote.restored(setupRuns: true, relocatedTo: "/tmp/w-2")
        #expect(moved.sentence.contains("setup script is running again"))
        #expect(moved.sentence.contains("/tmp/w-2"))
    }

    @Test("a note survives the trip through its stored row")
    func roundTrip() {
        for note in [
            WorkspaceLifecycleNote.archived(facts(hasSetupScript: true)),
            WorkspaceLifecycleNote.restored(setupRuns: true)
        ] {
            #expect(WorkspaceLifecycleNote(payload: note.payload) == note)
        }
    }

    @Test("other notice rows are not mistaken for one")
    func otherNotices() {
        #expect(WorkspaceLifecycleNote(payload: ConversationNotResumed.note) == nil)
        #expect(WorkspaceLifecycleNote(payload: Data(#"{"type":"rate_limit_event"}"#.utf8)) == nil)
        #expect(WorkspaceLifecycleNote(payload: Data()) == nil)
    }
}
