import Testing
@testable import BloomCore

/// The line along the foot of Home's list, which used to be four pieces of view state picking
/// between sentences inside a body.
///
/// The comment on its first clause recorded that the expression had already produced a wrong
/// answer once: "0 workspaces" about a machine holding three, printed directly above a panel
/// saying all three existed.
///
/// It has moved twice over. It came out of the body into here, and then out of the trailing end of
/// the chip strip into a status bar at the foot of the pane, where Finder puts "23 items". The
/// move is why it now follows the chip: standing an inch from five numbered chips it could afford
/// to ignore them, and standing beside the rows it has to be about the rows.
@Suite("What Home says about its list")
struct HomeSummaryTests {
    private func listing(
        shown: Int,
        considered: Int,
        live: Int = 0,
        archived: Int = 0,
        needsYou: Int = 0,
        running: Int = 0,
        workspaces: Int = 0,
        transcripts: Int = 0,
        isSearching: Bool = false,
        shownBytes: Int = 0
    ) -> HomeListing {
        var counts = HomeScopeCounts()
        counts.live = live
        counts.archived = archived
        counts.needsYou = needsYou
        counts.running = running
        counts.workspaces = workspaces
        counts.transcripts = transcripts
        return HomeListing(
            groups: [],
            counts: counts,
            isSearching: isSearching,
            shown: shown,
            considered: considered,
            archived: archived,
            shownArchived: archived,
            shownBytes: shownBytes
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

    /// "3 live in 1 project" is a fact about a machine that has no other kind, so the clause is
    /// dropped rather than printed with a one in it.
    @Test("the project clause appears only when there is more than one project")
    func projectsAreNamedWhenThereAreSeveral() {
        #expect(
            HomeList.summary(
                listing: listing(shown: 8, considered: 8, live: 8),
                filter: HomeFilter(scope: .live),
                projects: 1
            ) == "8 live"
        )
        #expect(
            HomeList.summary(
                listing: listing(shown: 8, considered: 8, live: 8),
                filter: HomeFilter(scope: .live),
                projects: 3
            ) == "8 live in 3 projects"
        )
    }

    /// Narrowed to Live the line is about live work, and the archived clause is the pointer to the
    /// scope that shows the rest: a list that leaves finished work out says out loud how much of it
    /// there is.
    ///
    /// Home no longer rests here, because the strip that offers the chips is `all` and `archived`
    /// alone. `RevealChoice.offered` still names `live`, so an agent can put the window in this
    /// scope, and this is the line the owner then reads.
    @Test("narrowed to Live, the line counts live work and names the archive")
    func theLiveLineIsAboutLiveWork() {
        #expect(
            HomeList.summary(
                listing: listing(shown: 3, considered: 20, live: 3, archived: 17),
                filter: HomeFilter(scope: .live),
                projects: 4
            ) == "3 live in 4 projects \u{00B7} 17 archived"
        )
    }

    /// "48 workspaces" reads very differently once you know 30 of them are over, and the split is
    /// the one thing the chips do not already say in the same breath.
    @Test("finished work is split out of the total under All")
    func archivedIsSplitOut() {
        #expect(
            HomeList.summary(
                listing: listing(shown: 48, considered: 48, live: 18, archived: 30),
                filter: HomeFilter(scope: .all),
                projects: 1
            ) == "48 workspaces \u{00B7} 18 live, 30 archived"
        )
        #expect(
            HomeList.summary(
                listing: listing(shown: 47, considered: 47, live: 35, archived: 12),
                filter: HomeFilter(scope: .all),
                projects: 6
            ) == "47 workspaces in 6 projects \u{00B7} 35 live, 12 archived"
        )
    }

    /// A machine with nothing archived says nothing about archiving. A trailing ", 0 archived" is
    /// a clause about an absence.
    @Test("a machine with nothing archived does not mention it")
    func nothingArchivedIsNotMentioned() {
        #expect(
            HomeList.summary(
                listing: listing(shown: 5, considered: 5, live: 5),
                filter: HomeFilter(scope: .all),
                projects: 1
            ) == "5 workspaces"
        )
        #expect(
            HomeList.summary(
                listing: listing(shown: 5, considered: 5, live: 5),
                filter: HomeFilter(scope: .live),
                projects: 1
            ) == "5 live"
        )
    }

    /// A count printed under the rows has to be a count OF the rows. Narrowed to Archived, the
    /// line that says how many workspaces the machine holds is answering a question nobody asked.
    @Test("the line follows the chip")
    func theLineFollowsTheChip() {
        let machine = listing(
            shown: 17, considered: 20, live: 3, archived: 17, needsYou: 2, running: 1
        )
        #expect(
            HomeList.summary(listing: machine, filter: HomeFilter(scope: .archived), projects: 4)
                == "17 archived in 4 projects"
        )
        #expect(
            HomeList.summary(listing: machine, filter: HomeFilter(scope: .needsYou), projects: 4)
                == "2 waiting on you"
        )
        #expect(
            HomeList.summary(listing: machine, filter: HomeFilter(scope: .running), projects: 4)
                == "1 running"
        )
    }

    /// A chip with nothing in it raises an empty state above this line, and "0 waiting on you"
    /// under it would be arithmetic where the pane is already using words.
    @Test("an empty scope says so in words rather than with a nought")
    func anEmptyScopeSaysSoInWords() {
        let quiet = listing(shown: 0, considered: 20, live: 3, archived: 17)
        #expect(
            HomeList.summary(listing: quiet, filter: HomeFilter(scope: .needsYou), projects: 4)
                == "Nothing waiting on you"
        )
        #expect(
            HomeList.summary(listing: quiet, filter: HomeFilter(scope: .running), projects: 4)
                == "Nothing running"
        )
        let allArchived = listing(shown: 0, considered: 17, live: 0, archived: 17)
        #expect(
            HomeList.summary(listing: allArchived, filter: HomeFilter(scope: .live), projects: 4)
                == "Nothing live \u{00B7} 17 archived"
        )
    }

    // MARK: - What the archive costs

    /// **This line is where a Settings pane's header and footer ended up.** Storage said "17
    /// archived workspaces, holding 7.6 MB" across its top and "Bloom's database is 44.3 MB"
    /// across its foot, and both are facts about the whole of something, which is what this bar
    /// is for. They belong in one sentence rather than in two windows: 7.6 MB of archived work
    /// inside a 44.3 MB file is a different afternoon from 7.6 MB inside a 500 MB one.
    @Test("the archived line carries what the archive holds and how big the file is")
    func theArchivedLineCarriesBothTotals() {
        let machine = listing(
            shown: 17, considered: 20, live: 3, archived: 17, shownBytes: 7_600_000
        )
        let tidy = DatabaseSize(pageSize: 4_096, pageCount: 10_000, freePageCount: 10)

        #expect(
            HomeList.summary(
                listing: machine, filter: HomeFilter(scope: .archived), projects: 4,
                database: tidy
            ) == "17 archived in 4 projects, holding \(ArchiveDeletion.bytes(7_600_000)) "
                + "\u{00B7} Bloom\u{2019}s database is \(ArchiveDeletion.bytes(40_960_000))"
        )
    }

    /// The unused half is printed only when a compaction is on offer, because that button is the
    /// only thing that can act on it and it needs a number to be about. A person who cannot do
    /// anything about 40 kB of free list does not need to be told it is there.
    @Test("the free space is named only when there is a compaction to explain")
    func namesFreeSpaceOnlyWhenItIsWorthReclaiming() {
        let machine = listing(shown: 17, considered: 20, archived: 17, shownBytes: 7_600_000)
        let loose = DatabaseSize(pageSize: 4_096, pageCount: 10_000, freePageCount: 4_000)

        let text = HomeList.summary(
            listing: machine, filter: HomeFilter(scope: .archived), projects: 1, database: loose
        )
        #expect(loose.isWorthCompacting)
        #expect(text.hasSuffix("\(ArchiveDeletion.bytes(16_384_000)) of it unused"))
        // No project clause on a machine with one project, which the size clauses must not have
        // quietly reintroduced.
        #expect(text.hasPrefix("17 archived, holding"))
    }

    /// Every other chip is about the list rather than about the disk, and a database size under a
    /// list of live work is an answer to a question that screen is not asking.
    @Test("the database is named under the Archived chip alone")
    func theDatabaseIsNamedOnlyUnderArchived() {
        let machine = listing(
            shown: 20, considered: 20, live: 3, archived: 17, shownBytes: 7_600_000
        )
        let size = DatabaseSize(pageSize: 4_096, pageCount: 10_000, freePageCount: 10)
        for scope in [HomeScope.all, .live, .needsYou, .running] {
            #expect(
                !HomeList.summary(
                    listing: machine, filter: HomeFilter(scope: scope), projects: 4, database: size
                ).contains("database")
            )
        }
    }

    /// Nothing archived and a database that is nonetheless large is worth saying in one breath:
    /// it is the answer to "why is this file so big" being "not because of the archive".
    @Test("an empty archive still says how big the file is")
    func anEmptyArchiveStillNamesTheFile() {
        let quiet = listing(shown: 0, considered: 20, live: 20, archived: 0)
        let size = DatabaseSize(pageSize: 4_096, pageCount: 10_000, freePageCount: 10)
        #expect(
            HomeList.summary(
                listing: quiet, filter: HomeFilter(scope: .archived), projects: 4, database: size
            ) == "Nothing archived \u{00B7} Bloom\u{2019}s database is "
                + "\(ArchiveDeletion.bytes(40_960_000))"
        )
    }

    /// The project menu answers before the chip does: narrowed to one project the line is
    /// "Showing 11 of 312 workspaces" and never reaches the archived branch at all, while the
    /// rows above it are each still drawing a size. A total that appeared and vanished with the
    /// project filter would be the one number on the screen that could not be trusted.
    @Test("a project filter narrows the line and keeps the storage on it")
    func aProjectFilterKeepsTheStorageClauses() {
        let machine = listing(shown: 11, considered: 312, archived: 11, shownBytes: 2_100_000)
        let size = DatabaseSize(pageSize: 4_096, pageCount: 10_000, freePageCount: 10)

        #expect(
            HomeList.summary(
                listing: machine,
                filter: HomeFilter(projects: [RepoID("a")], scope: .archived),
                projects: 4,
                database: size
            ) == "Showing 11 of 312 workspaces, holding \(ArchiveDeletion.bytes(2_100_000)) "
                + "\u{00B7} Bloom\u{2019}s database is \(ArchiveDeletion.bytes(40_960_000))"
        )
        // And nothing about bytes on any other chip, narrowed or not.
        #expect(
            HomeList.summary(
                listing: machine,
                filter: HomeFilter(projects: [RepoID("a")], scope: .all),
                projects: 4,
                database: size
            ) == "Showing 11 of 312 workspaces"
        )
    }

    /// Nobody has measured yet, which is every moment before the load lands and every chip that
    /// never asks. The line is the one it has always been rather than one with a hole in it.
    @Test("an unmeasured archive says nothing about bytes at all")
    func saysNothingBeforeAnythingIsMeasured() {
        let machine = listing(shown: 17, considered: 20, live: 3, archived: 17)
        #expect(
            HomeList.summary(listing: machine, filter: HomeFilter(scope: .archived), projects: 4)
                == "17 archived in 4 projects"
        )
    }

    /// Searching, the chips have already split the answer by kind, so the only fact left worth
    /// carrying is how many came back and what was asked.
    @Test("a search counts its results and quotes what was typed")
    func aSearchCountsResults() {
        let found = listing(
            shown: 4, considered: 47, workspaces: 4, transcripts: 37, isSearching: true
        )
        #expect(
            HomeList.summary(listing: found, filter: HomeFilter(query: "sidebar", scope: .all), projects: 6)
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
            filter: HomeFilter(query: "  blue  ", scope: .all),
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
