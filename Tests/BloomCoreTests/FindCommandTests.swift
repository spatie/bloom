import Testing
@testable import BloomCore

/// Cmd+F never finding what you are looking at.
///
/// It navigated to a separate Search screen, replacing the centre column, while the terminal in
/// front of the reader had a find bar nothing ever asked for.
@Suite("What Cmd+F finds")
struct FindCommandTests {
    /// The whole point: a shell or a source editor in front answers for itself and the reader is
    /// not thrown out to another screen.
    @Test("a pane that can find keeps the keystroke")
    func findsInPlace() {
        #expect(FindCommand.find(canFindInPlace: true, hasProjects: true) == .findInPlace)
        #expect(FindCommand.find(canFindInPlace: true, hasProjects: false) == .findInPlace)
    }

    /// And what Cmd+F has always done is still on the end of it, so nothing that worked stops
    /// working.
    @Test("a pane that cannot find falls through to the workspace search")
    func fallsThroughToSearch() {
        #expect(FindCommand.find(canFindInPlace: false, hasProjects: true) == .workspaceSearch)
    }

    @Test("with no projects there is nothing to find anywhere")
    func nothingToFind() {
        #expect(FindCommand.find(canFindInPlace: false, hasProjects: false) == nil)
    }

    /// Stepping the matches is the find in front and nothing else. Moving the sidebar's selection
    /// would not be finding a next anything.
    @Test("Cmd+G only ever means the find in front")
    func stepping() {
        #expect(FindCommand.step(canFindInPlace: true) == .findInPlace)
        #expect(FindCommand.step(canFindInPlace: false) == nil)
    }
}
