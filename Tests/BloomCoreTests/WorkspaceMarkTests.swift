import Testing
import Foundation
@testable import BloomCore

/// The two marks a person puts on a workspace by hand: the unread flag and the colour.
///
/// Both are offered from a row's context menu, both lists offer the same menu, and three other
/// things in the window read the unread flag. So the rules about what may be offered and what a
/// stored value means are settled here rather than in a view, where nothing could reach them.
@Suite("Workspace marks")
struct WorkspaceMarkTests {
    private func workspace(
        unread: Bool = false,
        state: WorkspaceState = .active,
        colour: String? = nil
    ) -> Workspace {
        Workspace(
            repoID: RepoID("r"), name: "w", branch: "b", path: "/tmp/w", baseBranch: "main",
            state: state, unread: unread, colour: colour
        )
    }

    // MARK: - The unread mark

    @Test("a read workspace is offered the mark, an unread one is offered its removal")
    func theItemChangesItsLabel() {
        #expect(WorkspaceUnreadMark.action(for: workspace()) == .markUnread)
        #expect(WorkspaceUnreadMark.action(for: workspace(unread: true)) == .markRead)
    }

    /// One item, so the two directions have to be one decision. What the item writes has to be the
    /// opposite of what the workspace already is, or pressing it twice would settle on one value.
    @Test("the item always writes the opposite of what is there")
    func theItemInverts() throws {
        for unread in [true, false] {
            let action = try #require(WorkspaceUnreadMark.action(for: workspace(unread: unread)))
            #expect(action.unread == !unread)
        }
    }

    @Test("the titles are the words the menu shows")
    func theTitlesAreTheWords() {
        #expect(UnreadMarkAction.markUnread.title == "Mark as Unread")
        #expect(UnreadMarkAction.markRead.title == "Mark as Read")
    }

    /// The rule `HomeListRow.isUnread` already holds to, said once so the two cannot drift.
    ///
    /// An archived workspace's `unread` is a leftover that nothing draws: the sidebar never lists
    /// one, `DockBadge` counts active workspaces only, and opening one marks nothing read. An item
    /// here would write a flag with no way to answer it.
    @Test("an archived workspace is offered nothing, however its flag stands")
    func archivedIsOfferedNothing() {
        #expect(WorkspaceUnreadMark.action(for: workspace(state: .archived)) == nil)
        #expect(WorkspaceUnreadMark.action(for: workspace(unread: true, state: .archived)) == nil)
    }

    // MARK: - The colour

    /// The whole reason `WorkspaceColour` exists rather than a second list of hexes. A workspace's
    /// dot sits a few points from its project's tile, and two reds that are nearly the same is
    /// worse than one red used twice.
    @Test("every colour offered is one of the ten the app already hands to projects")
    func theColoursAreTheAccentSet() {
        for colour in WorkspaceColour.all {
            #expect(Accent.all.contains(colour.hex), "\(colour.name) is not an accent colour")
        }
        #expect(Set(WorkspaceColour.all.map(\.hex)).count == WorkspaceColour.all.count)
        #expect(Set(WorkspaceColour.all.map(\.name)).count == WorkspaceColour.all.count)
        // Every accent is offered, not just some of them. A colour a project can have and a
        // workspace cannot would be a hole nobody could explain.
        #expect(Set(WorkspaceColour.all.map(\.hex)) == Set(Accent.all))
    }

    @Test("a stored colour is looked up whatever case it was written in")
    func lookupIgnoresCase() {
        #expect(WorkspaceColour.named("4C8DF6")?.name == "Blue")
        #expect(WorkspaceColour.named("4c8df6")?.name == "Blue")
        #expect(WorkspaceColour.named("nonsense") == nil)
    }

    /// A hex the menu has no name for is still a colour and is still drawn. The stored value is
    /// the truth; the list is only the menu's opinion of it.
    @Test("a colour outside the list is still a colour")
    func anUnlistedColourIsStillDrawn() {
        let subject = workspace(colour: "7F3FBF")
        #expect(subject.colourMark == HexColor(red: 0x7F, green: 0x3F, blue: 0xBF))
        #expect(subject.colourDescription == "#7F3FBF")
    }

    @Test("no colour, and a value that is not one, both draw nothing")
    func nonsenseDrawsNothing() {
        #expect(workspace().colourMark == nil)
        #expect(workspace().colourDescription == nil)
        #expect(workspace(colour: "not a colour").colourMark == nil)
        #expect(workspace(colour: "not a colour").colourDescription == nil)
        #expect(workspace(colour: "").colourMark == nil)
    }

    @Test("a colour in the list is described by its name")
    func aListedColourIsNamed() {
        #expect(workspace(colour: "22A06B").colourDescription == "Green")
    }
}
