import Testing
@testable import BloomCore

/// The line above Home's list, which used to be four pieces of view state picking between
/// sentences inside a body.
///
/// The comment on its first clause recorded that the expression had already produced a wrong
/// answer once: "0 workspaces" about a machine holding three, printed directly above a panel
/// saying all three existed. That is the case this suite starts with.
@Suite("What Home says about its list")
struct HomeSummaryTests {
    private func listing(
        shown: Int, considered: Int, archived: Int = 0, shownArchived: Int = 0
    ) -> HomeListing {
        HomeListing(
            groups: [], shown: shown, considered: considered,
            archived: archived, shownArchived: shownArchived
        )
    }

    /// The bug, written down. `considered` counts only what the archived switch let through, so
    /// on a machine where everything is archived and archived is hidden the general shape reports
    /// nothing at all about a machine that is full of work.
    @Test("a machine whose work is all archived and hidden is not reported as empty")
    func everythingArchivedAndHidden() {
        let text = HomeList.summary(
            listing: listing(shown: 0, considered: 0, archived: 3),
            isNarrowed: false, projects: 1, running: 0
        )
        #expect(text == "3 workspaces, all archived and hidden")
        #expect(!text.hasPrefix("0"))
    }

    /// A line reading "312 workspaces" above eleven rows is how a forgotten filter becomes a bug
    /// report about missing work.
    @Test("a narrowed list says what it was narrowed from")
    func aNarrowedListSaysSo() {
        let text = HomeList.summary(
            listing: listing(shown: 11, considered: 312),
            isNarrowed: true, projects: 4, running: 0
        )
        #expect(text.hasPrefix("Showing 11 of 312 workspaces"))
        // The project count belongs to the unnarrowed shape only: "of 312 across 4 projects"
        // would be counting two different things in one clause.
        #expect(!text.contains("across"))
    }

    @Test("an unnarrowed list names the projects only when there is more than one")
    func projectsAreNamedWhenThereAreSeveral() {
        #expect(
            HomeList.summary(
                listing: listing(shown: 8, considered: 8),
                isNarrowed: false, projects: 1, running: 0
            ) == "8 workspaces"
        )
        #expect(
            HomeList.summary(
                listing: listing(shown: 8, considered: 8),
                isNarrowed: false, projects: 3, running: 0
            ) == "8 workspaces across 3 projects"
        )
    }

    /// Both ways round, because the count in front of the clause is a count of what the archived
    /// switch let through: a machine with archived work it is not being shown hears about it here
    /// or nowhere.
    @Test("archived work is mentioned whether it is shown or hidden")
    func archivedIsAlwaysMentioned() {
        #expect(
            HomeList.summary(
                listing: listing(shown: 48, considered: 48, archived: 30, shownArchived: 30),
                isNarrowed: false, projects: 1, running: 0
            ) == "48 workspaces, 30 archived"
        )
        #expect(
            HomeList.summary(
                listing: listing(shown: 18, considered: 18, archived: 30),
                isNarrowed: false, projects: 1, running: 0
            ) == "18 workspaces, 30 archived hidden"
        )
    }

    @Test("running is added last and only when something is")
    func runningIsAddedLast() {
        #expect(
            HomeList.summary(
                listing: listing(shown: 5, considered: 5),
                isNarrowed: false, projects: 1, running: 2
            ) == "5 workspaces, 2 running"
        )
        #expect(
            !HomeList.summary(
                listing: listing(shown: 5, considered: 5),
                isNarrowed: false, projects: 1, running: 0
            ).contains("running")
        )
    }

    /// The strip is not drawn on a machine with no project, and there is nothing to count.
    @Test("nothing at all says nothing at all")
    func nothingSaysNothing() {
        #expect(
            HomeList.summary(
                listing: .empty, isNarrowed: false, projects: 0, running: 0
            ).isEmpty
        )
    }
}
