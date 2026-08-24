import Testing
import Foundation
@testable import BloomCore

/// The sentence three dialogs share, now that it can be read.
///
/// It came out of the app target because of the last case here. The owner removed a project while
/// an agent was still working in one of its workspaces, and the confirmation said nothing about
/// it: he found out from a modal reading "Could not store a system row: FOREIGN KEY constraint
/// failed". Archiving has warned about a running agent since it was written. Removing a project
/// takes every workspace the project has, all at once, and did not.
@Suite("Removing a project")
struct ProjectRemovalTests {
    private func workspace(_ name: String, state: WorkspaceState = .active) -> Workspace {
        var made = Workspace(
            repoID: RepoID("r"), name: name, branch: name, path: "/tmp/\(name)", baseBranch: "main"
        )
        if state != .active { made.archive() }
        return made
    }

    @Test("counts what goes, and says the folders stay")
    func countsTheWorkspaces() {
        let text = ProjectRemoval.consequences(
            workspaces: [workspace("one"), workspace("two")], runningAgents: 0
        )
        #expect(text.contains("its 2 active workspaces and their transcripts"))
        #expect(text.contains("Nothing on disk is deleted"))
        #expect(text.contains("the worktrees stay checked out"))
    }

    @Test("a project with nothing in it promises nothing about worktrees")
    func saysNothingAboutWorktreesThatDoNotExist() {
        let text = ProjectRemoval.consequences(workspaces: [], runningAgents: 0)
        #expect(text == "Bloom forgets this project. Nothing on disk is deleted: the repository stays where it is.")
    }

    @Test("archived workspaces are counted as archived")
    func countsArchivedSeparately() {
        let text = ProjectRemoval.consequences(
            workspaces: [workspace("gone", state: .archived)], runningAgents: 0
        )
        #expect(text.contains("its 1 archived workspace."))
        #expect(!text.contains("worktrees stay checked out"))
    }

    @Test("says when an agent is working, because removing the project stops it")
    func warnsAboutOneRunningAgent() {
        let text = ProjectRemoval.consequences(
            workspaces: [workspace("one"), workspace("two")], runningAgents: 1
        )
        #expect(text.contains("An agent is working in one of them right now, and it is stopped."))
    }

    @Test("counts them when there is more than one")
    func warnsAboutSeveralRunningAgents() {
        let text = ProjectRemoval.consequences(
            workspaces: [workspace("one"), workspace("two"), workspace("three")], runningAgents: 3
        )
        #expect(text.contains("Agents are working in 3 of them right now, and they are stopped."))
    }

    @Test("says nothing about agents when none are working")
    func saysNothingWhenNothingIsRunning() {
        let text = ProjectRemoval.consequences(workspaces: [workspace("one")], runningAgents: 0)
        #expect(!text.lowercased().contains("agent"))
    }
}
