import Testing
@testable import BloomCore

/// The line at the end of Home's strip, which used to be four pieces of view state picking between
/// sentences inside a body.
///
/// The comment on its first clause recorded that the expression had already produced a wrong
/// answer once: "0 workspaces" about a machine holding three, printed directly above a panel
/// saying all three existed.
///
/// It says less than it did, and that is the change to check for rather than a regression. The
/// archived count and the running count are chips on the same strip now, each carrying its own
/// number, so a clause repeating either of them here would be the same fact printed twice on one
/// line.
@Suite("What Home says about its list")
struct HomeSummaryTests {
    private func listing(
        shown: Int,
        considered: Int,
        live: Int = 0,
        archived: Int = 0,
        workspaces: Int = 0,
        transcripts: Int = 0,
        isSearching: Bool = false
    ) -> HomeListing {
        var counts = HomeScopeCounts()
        counts.live = live
        counts.archived = archived
        counts.workspaces = workspaces
        counts.transcripts = transcripts
        return HomeListing(
            groups: [],
            counts: counts,
            isSearching: isSearching,
            shown: shown,
            considered: considered,
            archived: archived,
            shownArchived: archived
        )
    }

    /// A line reading "312 workspaces" above eleven rows is how a forgotten filter becomes a bug
    /// report about missing work.
    @Test("a narrowed list says what it was narrowed from")
    func aNarrowedListSaysSo() {
        let text = HomeList.summary(
            listing: listing(shown: 11, considered: 312, live: 11),
            filter: HomeFilter(projects: [RepoID("a")]),
            projects: 4
        )
        #expect(text == "Showing 11 of 312 workspaces")
    }

    @Test("an unnarrowed list leads with projects only when there is more than one")
    func projectsAreNamedWhenThereAreSeveral() {
        #expect(
            HomeList.summary(
                listing: listing(shown: 8, considered: 8, live: 8),
                filter: HomeFilter(),
                projects: 1
            ) == "8 workspaces"
        )
        #expect(
            HomeList.summary(
                listing: listing(shown: 8, considered: 8, live: 8),
                filter: HomeFilter(),
                projects: 3
            ) == "3 projects \u{00B7} 8 live"
        )
    }

    /// "48 workspaces" reads very differently once you know 30 of them are over, and the split is
    /// the one thing on the strip the chips do not already say in the same breath.
    @Test("finished work is split out of the total")
    func archivedIsSplitOut() {
        #expect(
            HomeList.summary(
                listing: listing(shown: 48, considered: 48, live: 18, archived: 30),
                filter: HomeFilter(),
                projects: 1
            ) == "48 workspaces, 18 live, 30 archived"
        )
        #expect(
            HomeList.summary(
                listing: listing(shown: 47, considered: 47, live: 35, archived: 12),
                filter: HomeFilter(),
                projects: 6
            ) == "6 projects \u{00B7} 35 live, 12 archived"
        )
    }

    /// A machine with nothing archived says nothing about archiving. A trailing ", 0 archived" is
    /// a clause about an absence.
    @Test("a machine with nothing archived does not mention it")
    func nothingArchivedIsNotMentioned() {
        let text = HomeList.summary(
            listing: listing(shown: 5, considered: 5, live: 5),
            filter: HomeFilter(),
            projects: 1
        )
        #expect(text == "5 workspaces")
    }

    /// Searching, the chips have already split the answer by kind, so the only fact left worth
    /// carrying is how many came back and what was asked.
    @Test("a search counts its results and quotes what was typed")
    func aSearchCountsResults() {
        let found = listing(
            shown: 4, considered: 47, workspaces: 4, transcripts: 37, isSearching: true
        )
        #expect(
            HomeList.summary(listing: found, filter: HomeFilter(query: "sidebar"), projects: 6)
                == "41 results for \u{201C}sidebar\u{201D}"
        )
        // The count follows the chip, because the chip is what decided what is in the pane.
        #expect(
            HomeList.summary(
                listing: found,
                filter: HomeFilter(query: "sidebar", scope: .workspaces),
                projects: 6
            ) == "4 results for \u{201C}sidebar\u{201D}"
        )
    }

    /// Typographic quotes, and the query trimmed: a trailing space would otherwise be quoted back
    /// at the reader.
    @Test("the search sentence quotes the user properly")
    func theQuotesAreTypographic() {
        let text = HomeList.summary(
            listing: listing(shown: 1, considered: 4, workspaces: 1, isSearching: true),
            filter: HomeFilter(query: "  blue  "),
            projects: 1
        )
        #expect(text.contains("\u{201C}blue\u{201D}"))
        #expect(!text.contains("\""))
    }

    /// The strip is not drawn on a machine with no project, and there is nothing to count.
    @Test("nothing at all says nothing at all")
    func nothingSaysNothing() {
        #expect(HomeList.summary(listing: .empty, filter: HomeFilter(), projects: 0).isEmpty)
    }
}
