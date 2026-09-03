import Foundation
import Testing
@testable import BloomCore

/// Home's list, its date headings and its ages.
///
/// Every date in here is built rather than read off the clock. A suite that says "two days ago"
/// as `Date().addingTimeInterval(-172_800)` passes all afternoon and fails at midnight, which is
/// the one moment the arithmetic under test is worth checking. The calendar is fixed too: it
/// carries a zone with daylight saving in it and an English locale, so the month headings spell
/// the same way on every machine that runs this.
@Suite("Home list")
struct HomeListTests {
    // MARK: - Fixtures

    /// Brussels, deliberately: it is an hour off UTC, it observes daylight saving, and the tests
    /// below stand dates either side of both boundaries.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Brussels")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return Self.calendar.date(from: components)!
    }

    private func workspace(
        _ name: String,
        repoID: RepoID = RepoID("repo"),
        branch: String? = nil,
        at activity: Date = Date(),
        state: WorkspaceState = .active
    ) -> Workspace {
        Workspace(
            id: WorkspaceID(name),
            repoID: repoID,
            name: name,
            branch: branch ?? "feature/\(name)",
            path: "/tmp/\(name)",
            baseBranch: "main",
            state: state,
            lastActivityAt: activity
        )
    }

    private func repo(_ id: String, name: String? = nil) -> Repo {
        Repo(id: RepoID(id), name: name ?? id, path: "/tmp/\(id)")
    }

    /// What one archived record holds, as the store would have measured it. Only the bytes and
    /// the identity matter to the list, so the rest is left at nought rather than invented.
    private func footprint(_ name: String, bytes: Int) -> ArchivedWorkspaceFootprint {
        ArchivedWorkspaceFootprint(
            workspace: workspace(name, state: .archived),
            repoName: "repo",
            sessionCount: 0,
            messageCount: 0,
            transcriptBytes: bytes,
            otherBytes: 0,
            reviewCommentCount: 0,
            hasNote: false
        )
    }

    private func bucket(_ activity: Date, now: Date) -> HomeList.Bucket {
        HomeList.bucket(for: activity, now: now, calendar: Self.calendar)
    }

    // MARK: - Buckets, near

    @Test("a workspace touched seconds ago is under Today")
    func secondsAgoIsToday() {
        let now = date(2025, 8, 19, 14, 30, 0)
        #expect(bucket(now.addingTimeInterval(-3), now: now).title == "Today")
    }

    @Test("midnight exactly is already Today, not yesterday's last minute")
    func midnightIsToday() {
        let now = date(2025, 8, 19, 9, 0, 0)
        let midnight = Self.calendar.startOfDay(for: now)

        #expect(bucket(midnight, now: now) == HomeList.Bucket(id: "day-0", title: "Today"))
    }

    @Test("one second before midnight is Yesterday")
    func justBeforeMidnightIsYesterday() {
        let now = date(2025, 8, 19, 9, 0, 0)
        let lastSecond = date(2025, 8, 18, 23, 59, 59)

        #expect(bucket(lastSecond, now: now) == HomeList.Bucket(id: "day-1", title: "Yesterday"))
    }

    /// The whole reason the buckets are counted in calendar days rather than in elapsed hours.
    @Test("23:30 and 00:30 are an hour apart and under two different headings")
    func midnightSplitsAnHour() {
        let now = date(2025, 8, 19, 8, 0, 0)
        let lateLastNight = date(2025, 8, 18, 23, 30, 0)
        let earlyThisMorning = date(2025, 8, 19, 0, 30, 0)

        #expect(earlyThisMorning.timeIntervalSince(lateLastNight) == 3_600)
        #expect(bucket(lateLastNight, now: now).title == "Yesterday")
        #expect(bucket(earlyThisMorning, now: now).title == "Today")
    }

    /// The same point, from the other side: a gap far wider than a day that is still one day.
    @Test("twenty-three hours ago is still Yesterday when a day boundary is in between")
    func longGapWithinOneDay() {
        let now = date(2025, 8, 19, 23, 0, 0)
        let earlyYesterday = date(2025, 8, 18, 0, 30, 0)

        #expect(now.timeIntervalSince(earlyYesterday) > 46 * 3_600)
        #expect(bucket(earlyYesterday, now: now).title == "Yesterday")
    }

    /// The clocks go forward in Brussels at 02:00 on 30 March 2025, so that day is 23 hours long.
    /// Twenty-two elapsed hours span the midnight before it, and the heading has to say so.
    @Test("a short daylight saving day still reads as Yesterday under 24 hours")
    func daylightSavingShortDay() {
        let now = date(2025, 3, 30, 22, 0, 0)
        let lastNight = date(2025, 3, 29, 23, 0, 0)

        #expect(now.timeIntervalSince(lastNight) == 22 * 3_600)
        #expect(bucket(lastNight, now: now).title == "Yesterday")
    }

    @Test(
        "days two to six are counted in days",
        arguments: [(2, "2 days ago"), (3, "3 days ago"), (6, "6 days ago")]
    )
    func dayHeadings(daysBack: Int, title: String) {
        let now = date(2025, 8, 19, 10, 0, 0)
        let then = Self.calendar.date(byAdding: .day, value: -daysBack, to: now)!

        #expect(bucket(then, now: now) == HomeList.Bucket(id: "day-\(daysBack)", title: title))
    }

    @Test(
        "a week is singular and the rest are not",
        arguments: [(7, "Last week"), (13, "Last week"), (14, "2 weeks ago"), (27, "3 weeks ago")]
    )
    func weekHeadings(daysBack: Int, title: String) {
        let now = date(2025, 8, 19, 10, 0, 0)
        let then = Self.calendar.date(byAdding: .day, value: -daysBack, to: now)!

        #expect(bucket(then, now: now).title == title)
    }

    // MARK: - Buckets, far

    @Test("a day count under a week wins over the month it fell in")
    func monthBoundaryStaysADayCount() {
        let now = date(2025, 9, 2, 10, 0, 0)
        let lastMonth = date(2025, 8, 31, 22, 0, 0)

        #expect(bucket(lastMonth, now: now).title == "2 days ago")
    }

    @Test("28 days back inside the same month says so rather than naming the month")
    func earlierThisMonth() {
        let now = date(2025, 1, 31, 10, 0, 0)
        let then = date(2025, 1, 3, 9, 0, 0)

        let result = bucket(then, now: now)

        #expect(result.title == "Earlier this month")
        #expect(result.id == "month-2025-1")
    }

    @Test("an earlier month of this year is named without the year")
    func earlierMonthThisYear() {
        let now = date(2025, 10, 5, 10, 0, 0)
        let then = date(2025, 8, 20, 9, 0, 0)

        let result = bucket(then, now: now)

        #expect(result.title == "August")
        #expect(result.id == "month-2025-8")
    }

    @Test("a month in a previous year carries the year")
    func monthInPreviousYear() {
        let now = date(2025, 2, 10, 10, 0, 0)
        let then = date(2024, 12, 15, 9, 0, 0)

        let result = bucket(then, now: now)

        #expect(result.title == "December 2024")
        #expect(result.id == "month-2024-12")
    }

    /// The reason the id is not the title: two Augusts spell the same and are not the same group.
    @Test("the same month in two years does not collide")
    func yearBoundaryKeepsIdsApart() {
        let now = date(2025, 10, 5, 10, 0, 0)
        let thisAugust = bucket(date(2025, 8, 20, 9, 0, 0), now: now)
        let lastAugust = bucket(date(2024, 8, 20, 9, 0, 0), now: now)

        #expect(thisAugust.id != lastAugust.id)
        #expect(thisAugust.title == "August")
        #expect(lastAugust.title == "August 2024")
    }

    @Test("the last day of a year and the first of the next are two groups")
    func newYearSplitsTheMonths() {
        let now = date(2025, 3, 1, 10, 0, 0)
        let december = bucket(date(2024, 12, 31, 23, 0, 0), now: now)
        let january = bucket(date(2025, 1, 1, 1, 0, 0), now: now)

        #expect(december.id == "month-2024-12")
        #expect(january.id == "month-2025-1")
        #expect(december.title == "December 2024")
        #expect(january.title == "January")
    }

    /// A clock change or a restore from backup stamps activity in the future. The heading has to
    /// stay a heading rather than becoming "-1 days ago".
    @Test("a timestamp from the future lands under Today")
    func futureIsToday() {
        let now = date(2025, 8, 19, 10, 0, 0)

        #expect(bucket(now.addingTimeInterval(3_600), now: now).title == "Today")
        #expect(bucket(date(2025, 8, 23, 10, 0, 0), now: now).title == "Today")
        #expect(bucket(date(2027, 1, 1, 10, 0, 0), now: now).title == "Today")
    }

    /// The bucket id and its title have to be worked out in the same zone, or the first and last
    /// day of a month are filed under one month and labelled with another.
    @Test("the heading is spelled in the same calendar the bucket was counted in")
    func headingFollowsTheCalendar() {
        var honolulu = Self.calendar
        honolulu.timeZone = TimeZone(identifier: "Pacific/Honolulu")!

        // 1 September 2025, 04:00 in Brussels, which is still 31 August in Honolulu.
        let instant = date(2025, 9, 1, 4, 0, 0)
        let now = date(2025, 11, 5, 10, 0, 0)

        let brussels = HomeList.bucket(for: instant, now: now, calendar: Self.calendar)
        let hawaii = HomeList.bucket(for: instant, now: now, calendar: honolulu)

        #expect(brussels.id == "month-2025-9")
        #expect(brussels.title == "September")
        #expect(hawaii.id == "month-2025-8")
        #expect(hawaii.title == "August")
    }

    // MARK: - Ages

    /// Annotated and hoisted rather than written inline. A literal of this many heterogeneous
    /// tuples sends the type checker over its own time limit inside a `@Test` macro expansion.
    static let ageCases: [(seconds: TimeInterval, expected: String)] = [
        (0, "now"),
        (3, "now"),
        (59, "now"),
        (60, "1m"),
        (90, "1m"),
        (3_540, "59m"),
        (3_600, "1h"),
        (5_400, "1h"),
        (82_800, "23h"),
        (86_400, "1d"),
        (518_400, "6d"),
        (604_800, "1w"),
        (2_937_600, "4w"),
        (3_024_000, "1mo"),
        (31_449_600, "12mo"),
        (31_536_000, "1y"),
        (77_760_000, "2y"),
    ]

    @Test("the age column stays two or three characters", arguments: ageCases)
    func ages(secondsAgo: TimeInterval, expected: String) {
        let now = date(2025, 8, 19, 10, 0, 0)

        #expect(HomeAge.short(for: now.addingTimeInterval(-secondsAgo), now: now) == expected)
    }

    /// Thirty-day months reach a year at day 360, the calendar reaches it at day 365, and the
    /// five days in between used to print "0y".
    @Test("the days either side of a year never print a zero")
    func neverPrintsZeroYears() {
        let now = date(2025, 8, 19, 10, 0, 0)

        for daysBack in 355...370 {
            let age = HomeAge.short(for: now.addingTimeInterval(-Double(daysBack) * 86_400), now: now)
            #expect(!age.hasPrefix("0"), "\(daysBack) days ago printed \(age)")
        }
    }

    @Test("a timestamp from the future reads as now rather than as a negative age")
    func futureAge() {
        let now = date(2025, 8, 19, 10, 0, 0)

        #expect(HomeAge.short(for: now.addingTimeInterval(90), now: now) == "now")
        #expect(HomeAge.short(for: now.addingTimeInterval(86_400 * 30), now: now) == "now")
    }

    // MARK: - Building the listing

    @Test("rows come out newest first, across every project")
    func sortsByRecency() {
        let now = date(2025, 8, 19, 12, 0, 0)
        let listing = HomeList.build(
            repos: [repo("a"), repo("b")],
            workspaces: [
                workspace("old", repoID: RepoID("a"), at: date(2025, 8, 1, 9, 0, 0)),
                workspace("newest", repoID: RepoID("b"), at: date(2025, 8, 19, 11, 0, 0)),
                workspace("middle", repoID: RepoID("a"), at: date(2025, 8, 18, 11, 0, 0)),
            ],
            archived: [],
            filter: HomeFilter(),
            now: now,
            calendar: Self.calendar
        )

        #expect(listing.groups.flatMap(\.rows).map(\.id.rawValue) == ["newest", "middle", "old"])
        #expect(listing.groups.map(\.title) == ["Today", "Yesterday", "2 weeks ago"])
        #expect(listing.shown == 3)
        #expect(listing.considered == 3)
    }

    @Test("every row carries the project it belongs to")
    func rowsCarryTheirRepo() {
        let now = date(2025, 8, 19, 12, 0, 0)
        let listing = HomeList.build(
            repos: [repo("a", name: "Bloom")],
            workspaces: [
                workspace("known", repoID: RepoID("a"), at: now),
                workspace("orphan", repoID: RepoID("gone"), at: now),
            ],
            archived: [],
            filter: HomeFilter(),
            now: now,
            calendar: Self.calendar
        )

        let rows = listing.groups.flatMap(\.rows)
        #expect(rows.first { $0.id == WorkspaceID("known") }?.repo?.name == "Bloom")
        #expect(rows.first { $0.id == WorkspaceID("orphan") }?.repo == nil)
    }

    @Test("two workspaces on the same day share one heading")
    func sameDayIsOneGroup() {
        let now = date(2025, 8, 19, 23, 0, 0)
        let listing = HomeList.build(
            repos: [repo("a")],
            workspaces: [
                workspace("early", at: date(2025, 8, 19, 0, 30, 0)),
                workspace("late", at: date(2025, 8, 19, 22, 30, 0)),
            ],
            archived: [],
            filter: HomeFilter(),
            now: now,
            calendar: Self.calendar
        )

        #expect(listing.groups.count == 1)
        #expect(listing.groups.first?.rows.count == 2)
    }

    /// **The default is `all` and this is the test that pins it.** It was `live`, and the argument
    /// for that is still on the record in `HomeScope.resting(searching:)`; what settled it was the
    /// strip losing its Live chip, because a resting scope with no chip on the strip is a state
    /// nobody can see they are in and nobody can leave.
    ///
    /// So the resting page is the whole machine in one date-ordered list, live and archived rows
    /// together, and the counts are still kept apart, which is the second half of what is checked
    /// here: the Archived chip carries its own number whatever is being shown.
    @Test("Home lists everything by default, and still counts the live and archived halves apart")
    func allIsTheDefaultAndTheHalvesAreStillCounted() {
        let now = date(2025, 8, 19, 12, 0, 0)
        let archived = [
            workspace("gone", at: date(2025, 8, 18, 9, 0, 0), state: .archived),
            workspace("older", at: date(2025, 8, 10, 9, 0, 0), state: .archived),
        ]

        let resting = HomeList.build(
            repos: [repo("repo")],
            workspaces: [workspace("live", at: now)],
            archived: archived,
            filter: HomeFilter(),
            now: now,
            calendar: Self.calendar
        )

        #expect(HomeFilter().scope == .all)
        #expect(resting.shown == 3)
        // Every workspace on the machine is considered whichever chip is lit: the chips have to
        // count what clicking them would show, so the pass cannot stop at the selected one.
        #expect(resting.considered == 3)
        #expect(resting.archived == 2)
        #expect(resting.shownArchived == 2)
        #expect(resting.counts.archived == 2)
        #expect(resting.counts.live == 1)
        // One date-ordered list, with the archived rows in their place in it rather than under it.
        #expect(
            resting.groups.flatMap(\.rows).map(\.id.rawValue) == ["live", "gone", "older"]
        )

        // Naming the scope by hand gets the same page, which is what makes the default invisible
        // rather than merely quiet.
        let named = HomeList.build(
            repos: [repo("repo")],
            workspaces: [workspace("live", at: now)],
            archived: archived,
            filter: HomeFilter(scope: .all),
            now: now,
            calendar: Self.calendar
        )

        #expect(named.groups.flatMap(\.rows).map(\.id.rawValue) == ["live", "gone", "older"])
        #expect(named.shownArchived == resting.shownArchived)
    }

    @Test("an archived row sorts by recency like any other, not to the bottom")
    func archivedSortsInline() {
        let now = date(2025, 8, 19, 12, 0, 0)
        let listing = HomeList.build(
            repos: [repo("repo")],
            workspaces: [workspace("old", at: date(2025, 8, 1, 9, 0, 0))],
            archived: [workspace("recent", at: now, state: .archived)],
            filter: HomeFilter(scope: .all),
            now: now,
            calendar: Self.calendar
        )

        #expect(listing.groups.flatMap(\.rows).map(\.id.rawValue) == ["recent", "old"])
        #expect(listing.groups.flatMap(\.rows).map(\.isArchived) == [true, false])
    }

    // MARK: - What the archive costs

    /// **The Archived chip is where the Settings > Storage pane went, and this is the seam.** The
    /// rows are the ones Home was already drawing; what arrives with them is the measurement, and
    /// it arrives on that chip and on no other, because under All the same column would hold a
    /// size on the archived rows and a diff on the live ones.
    @Test("sizes reach the rows under the Archived chip and nowhere else")
    func sizesOnlyUnderArchived() {
        let now = date(2025, 8, 19, 12, 0, 0)
        let archived = [
            workspace("gone", at: date(2025, 8, 18, 9, 0, 0), state: .archived),
            workspace("older", at: date(2025, 8, 10, 9, 0, 0), state: .archived),
        ]
        let measured = ArchiveCleanup(footprints: [
            footprint("gone", bytes: 4_000), footprint("older", bytes: 90),
        ])

        func rows(_ scope: HomeScope) -> [HomeRow] {
            HomeList.build(
                repos: [repo("repo")],
                workspaces: [workspace("live", at: now)],
                archived: archived,
                filter: HomeFilter(scope: scope),
                footprints: measured,
                now: now,
                calendar: Self.calendar
            ).groups.flatMap(\.rows)
        }

        #expect(rows(.all).compactMap(\.bytes).isEmpty)
        #expect(rows(.archived).map(\.bytes) == [4_000, 90])
        // The whole footprint travels, because the row has two more uses for it and both are
        // words rather than a column. See `ArchivedWorkspaceFootprint.contents`.
        #expect(rows(.archived).first?.footprint?.repoName == "repo")
    }

    /// The status bar's total is over the rows in the list, not over the machine, because it is
    /// read at the foot of the list rather than beside the chips.
    @Test("the total is what the rows on screen hold")
    func totalsTheRowsShown() {
        let now = date(2025, 8, 19, 12, 0, 0)
        let listing = HomeList.build(
            repos: [repo("repo")],
            workspaces: [workspace("live", at: now)],
            archived: [
                workspace("gone", at: now, state: .archived),
                workspace("older", at: now, state: .archived),
            ],
            filter: HomeFilter(scope: .archived),
            footprints: ArchiveCleanup(footprints: [
                footprint("gone", bytes: 4_000), footprint("older", bytes: 90),
            ]),
            now: now,
            calendar: Self.calendar
        )

        #expect(listing.shownBytes == 4_090)
    }

    /// **A size order and the date headings cannot both be true, so the headings go.** Ordering by
    /// bytes puts a workspace from March above one from yesterday, and every heading over them is
    /// then a lie; sorting inside each heading instead leaves the largest record on the machine
    /// halfway down the list, which is the one place nobody looking for it will look. One group
    /// with one heading, exactly as a search already does to them.
    @Test("ordered by size, the list is one group and the date headings go")
    func largestFirstFlattensTheHeadings() {
        let now = date(2025, 8, 19, 12, 0, 0)
        let listing = HomeList.build(
            repos: [repo("repo")],
            workspaces: [],
            archived: [
                workspace("yesterday", at: date(2025, 8, 18, 9, 0, 0), state: .archived),
                workspace("march", at: date(2025, 3, 2, 9, 0, 0), state: .archived),
            ],
            filter: HomeFilter(scope: .archived, order: .largest),
            footprints: ArchiveCleanup(footprints: [
                footprint("yesterday", bytes: 12), footprint("march", bytes: 900_000),
            ]),
            now: now,
            calendar: Self.calendar
        )

        #expect(listing.groups.count == 1)
        #expect(listing.groups[0].title == "Largest first")
        #expect(listing.groups[0].rows.map(\.id.rawValue) == ["march", "yesterday"])

        // And the same rows in date order, under the headings, when the order is not asked for.
        let dated = HomeList.build(
            repos: [repo("repo")],
            workspaces: [],
            archived: [
                workspace("yesterday", at: date(2025, 8, 18, 9, 0, 0), state: .archived),
                workspace("march", at: date(2025, 3, 2, 9, 0, 0), state: .archived),
            ],
            filter: HomeFilter(scope: .archived),
            footprints: ArchiveCleanup(footprints: [
                footprint("yesterday", bytes: 12), footprint("march", bytes: 900_000),
            ]),
            now: now,
            calendar: Self.calendar
        )
        #expect(dated.groups.map(\.title) == ["Yesterday", "March"])
    }

    /// Two workspaces archived by the same script in the same second hold the same bytes, and a
    /// list that reshuffles them between two refreshes is a list somebody clicks the wrong row in.
    /// A row nobody has measured sorts as nought rather than to the top.
    @Test("equal sizes keep a stable order, and an unmeasured row does not float")
    func largestFirstBreaksTiesStably() {
        let now = date(2025, 8, 19, 12, 0, 0)
        let listing = HomeList.build(
            repos: [repo("repo")],
            workspaces: [],
            archived: [
                workspace("b", at: now, state: .archived),
                workspace("a", at: now, state: .archived),
                workspace("unmeasured", at: now, state: .archived),
            ],
            filter: HomeFilter(scope: .archived, order: .largest),
            footprints: ArchiveCleanup(footprints: [
                footprint("b", bytes: 100), footprint("a", bytes: 100),
            ]),
            now: now,
            calendar: Self.calendar
        )

        #expect(listing.groups[0].rows.map(\.id.rawValue) == ["a", "b", "unmeasured"])
    }

    /// The order is refused rather than settled away in the filter, so a chip that draws no sizes
    /// cannot be sorted by them and the Archived chip is still on Largest when you come back to
    /// it. See `HomeOrder.applies`.
    @Test("a size order asked for outside the Archived chip is ignored, not remembered wrongly")
    func sizeOrderAppliesOnlyWhereItIsOffered() {
        let now = date(2025, 8, 19, 12, 0, 0)
        #expect(!HomeOrder.applies(scope: .all, searching: false))
        #expect(!HomeOrder.applies(scope: .archived, searching: true))
        #expect(HomeOrder.applies(scope: .archived, searching: false))

        let listing = HomeList.build(
            repos: [repo("repo")],
            workspaces: [workspace("live", at: now)],
            archived: [workspace("huge", at: date(2025, 3, 2, 9, 0, 0), state: .archived)],
            filter: HomeFilter(scope: .all, order: .largest),
            footprints: ArchiveCleanup(footprints: [footprint("huge", bytes: 900_000)]),
            now: now,
            calendar: Self.calendar
        )

        #expect(listing.groups.map(\.title) == ["Today", "March"])
        #expect(listing.groups.flatMap(\.rows).map(\.id.rawValue) == ["live", "huge"])
    }

    @Test("the search reaches the name, the branch and the project, in any case")
    func searchMatchesThreeFields() {
        let now = date(2025, 8, 19, 12, 0, 0)
        let repos = [repo("a", name: "Bloom"), repo("b", name: "Baton")]
        let workspaces = [
            workspace("Sidebar rewrite", repoID: RepoID("a"), branch: "feature/sidebar", at: now),
            workspace("Diff colours", repoID: RepoID("b"), branch: "feature/palette", at: now),
        ]

        func ids(_ query: String) -> [String] {
            HomeList.build(
                repos: repos,
                workspaces: workspaces,
                archived: [],
                filter: HomeFilter(query: query, scope: .all),
                now: now,
                calendar: Self.calendar
            ).groups.flatMap(\.rows).map(\.id.rawValue)
        }

        #expect(ids("SIDEBAR") == ["Sidebar rewrite"])
        #expect(ids("palette") == ["Diff colours"])
        #expect(ids("baton") == ["Diff colours"])
        #expect(ids("  ") == ["Sidebar rewrite", "Diff colours"])
        #expect(ids("  sidebar  ") == ["Sidebar rewrite"])
        #expect(ids("nothing at all").isEmpty)
    }

    @Test("the project filter narrows the list but not the total it was narrowed from")
    func projectFilterKeepsTheTotal() {
        let now = date(2025, 8, 19, 12, 0, 0)
        let listing = HomeList.build(
            repos: [repo("a"), repo("b")],
            workspaces: [
                workspace("one", repoID: RepoID("a"), at: now),
                workspace("two", repoID: RepoID("b"), at: now),
                workspace("three", repoID: RepoID("b"), at: now),
            ],
            archived: [],
            filter: HomeFilter(projects: [RepoID("b")]),
            now: now,
            calendar: Self.calendar
        )

        #expect(listing.shown == 2)
        #expect(listing.considered == 3)
    }

    @Test("no chosen project means every project")
    func emptyProjectSetShowsEverything() {
        let now = date(2025, 8, 19, 12, 0, 0)
        let listing = HomeList.build(
            repos: [repo("a"), repo("b")],
            workspaces: [
                workspace("one", repoID: RepoID("a"), at: now),
                workspace("two", repoID: RepoID("b"), at: now),
            ],
            archived: [],
            filter: HomeFilter(),
            now: now,
            calendar: Self.calendar
        )

        #expect(listing.shown == 2)
        #expect(!HomeFilter().isNarrowed)
    }

    @Test("nothing to show is an empty listing rather than an empty group")
    func emptyListing() {
        let now = date(2025, 8, 19, 12, 0, 0)
        let listing = HomeList.build(
            repos: [], workspaces: [], archived: [], filter: HomeFilter(),
            now: now, calendar: Self.calendar
        )

        #expect(listing.isEmpty)
        #expect(listing.groups.isEmpty)
        #expect(HomeListing.empty.isEmpty)
    }

    @Test("a filter is narrowed by a real query or a chosen project, not by whitespace")
    func narrowing() {
        #expect(!HomeFilter().isNarrowed)
        #expect(!HomeFilter(query: "   ").isNarrowed)
        #expect(HomeFilter(query: "sidebar").isNarrowed)
        #expect(HomeFilter(projects: [RepoID("a")]).isNarrowed)
        // A scope narrows the list and is still deliberately not a narrowing by this measure:
        // `isNarrowed` drives a "showing 11 of 312" readout, and the chip that did it is carrying
        // its own count an inch to the left of that sentence.
        #expect(!HomeFilter(scope: .live).isNarrowed)
        #expect(!HomeFilter(scope: .needsYou).isNarrowed)
    }

    // MARK: - Searching

    private func transcriptResult(_ workspace: String, matches: Int) -> TranscriptWorkspaceMatches {
        TranscriptWorkspaceMatches(
            workspaceID: WorkspaceID(workspace),
            matches: (0..<min(matches, 3)).map { seq in
                TranscriptMatch(
                    messageID: Int64(seq),
                    workspaceID: WorkspaceID(workspace),
                    sessionID: SessionID("s-\(workspace)"),
                    sessionTitle: "Session",
                    seq: seq,
                    kind: .assistantText,
                    createdAt: Date(timeIntervalSince1970: 0),
                    snippet: TranscriptSnippet(segments: []),
                    score: -1
                )
            },
            total: matches
        )
    }

    /// A row can be a perfect answer with nothing on it that looks like what was typed: the search
    /// reaches the branch and the project as well as the name, and a list of workspaces with no
    /// visible connection to the query is what searching a branch name used to produce.
    @Test("a row says which field answered, unless it was the name")
    func aRowCarriesWhatMatched() {
        let now = date(2025, 8, 19, 12, 0, 0)
        func rows(_ query: String) -> [HomeRow] {
            HomeList.build(
                repos: [repo("a", name: "Bloom")],
                workspaces: [
                    workspace("Sidebar rewrite", repoID: RepoID("a"), branch: "agent/glass", at: now),
                ],
                archived: [],
                filter: HomeFilter(query: query, scope: .all),
                now: now,
                calendar: Self.calendar
            ).groups.flatMap(\.rows)
        }

        #expect(rows("glass").first?.match == "agent/glass")
        #expect(rows("bloom").first?.match == "Bloom")
        // The name is already on the row, so repeating it beside itself would be noise.
        #expect(rows("sidebar").first?.match == nil)
        // And nothing carries a match outside a search.
        #expect(rows("").first?.match == nil)
    }

    /// Searching, the date buckets go. A result list under headings that say "3 weeks ago" answers
    /// a question nobody asked: what was typed is the question, and the heading over the answer
    /// says which KIND of thing matched.
    ///
    /// It is still ONE group in one list, which is what keeps the arrow keys and Return working
    /// with one keyboard model rather than two.
    @Test("a search gathers the rows under one heading instead of date buckets")
    func aSearchIsOneGroup() {
        let now = date(2025, 8, 19, 12, 0, 0)
        let listing = HomeList.build(
            repos: [repo("repo", name: "Bloom")],
            workspaces: [
                workspace("sidebar today", at: now),
                workspace("sidebar last month", at: date(2025, 6, 1, 9, 0, 0)),
            ],
            archived: [],
            filter: HomeFilter(query: "sidebar", scope: .all),
            now: now,
            calendar: Self.calendar
        )

        #expect(listing.isSearching)
        #expect(listing.groups.count == 1)
        #expect(listing.groups.first?.title == "Workspaces")
        // Still newest first inside it.
        #expect(listing.groups.first?.rows.map(\.id.rawValue) == ["sidebar today", "sidebar last month"])
    }

    /// **The half that only ever existed on the screen that has gone.** Home's field never touched
    /// the full text index, so merging the two is not deleting a screen, it is Home gaining a
    /// second kind of result.
    @Test("the transcript results are a second kind of result, counted separately")
    func transcriptsAreASecondKindOfResult() {
        let now = date(2025, 8, 19, 12, 0, 0)
        let listing = HomeList.build(
            repos: [repo("repo", name: "Bloom")],
            workspaces: [workspace("sidebar rewrite", at: now), workspace("quiet", at: now)],
            archived: [],
            transcripts: [
                transcriptResult("quiet", matches: 6),
                transcriptResult("sidebar rewrite", matches: 4),
            ],
            filter: HomeFilter(query: "sidebar", scope: .all),
            now: now,
            calendar: Self.calendar
        )

        #expect(listing.counts.workspaces == 1)
        #expect(listing.counts.transcripts == 10)
        #expect(listing.counts.transcriptWorkspaces == 2)
        #expect(listing.counts.count(of: .all, searching: true) == 11)
        #expect(listing.transcripts.count == 2)
        // A workspace that matched by name AND in its transcript is in both halves, on purpose:
        // they are two different answers to the query and either may be the one wanted.
        #expect(listing.groups.flatMap(\.rows).map(\.id.rawValue) == ["sidebar rewrite"])
    }

    /// The store answers about every workspace on the machine, so the project menu has to reach
    /// the transcript half too. Without this, a list narrowed to one project still showed what the
    /// agents said in the others.
    @Test("the project filter reaches the transcript results")
    func theProjectFilterReachesTranscripts() {
        let now = date(2025, 8, 19, 12, 0, 0)
        let listing = HomeList.build(
            repos: [repo("a", name: "Bloom"), repo("b", name: "Baton")],
            workspaces: [
                workspace("one", repoID: RepoID("a"), at: now),
                workspace("two", repoID: RepoID("b"), at: now),
            ],
            archived: [],
            transcripts: [transcriptResult("one", matches: 3), transcriptResult("two", matches: 9)],
            filter: HomeFilter(query: "sidebar", projects: [RepoID("a")], scope: .all),
            now: now,
            calendar: Self.calendar
        )

        #expect(listing.transcripts.map(\.workspaceID.rawValue) == ["one"])
        #expect(listing.counts.transcripts == 3)
    }

    /// A result whose workspace is in neither list has been deleted since the index was written,
    /// and there is nothing left to open.
    @Test("a transcript result for a workspace that is gone is dropped")
    func aStrandedTranscriptResultIsDropped() {
        let now = date(2025, 8, 19, 12, 0, 0)
        let listing = HomeList.build(
            repos: [repo("repo")],
            workspaces: [workspace("here", at: now)],
            archived: [],
            transcripts: [transcriptResult("deleted", matches: 4)],
            filter: HomeFilter(query: "sidebar", scope: .all),
            now: now,
            calendar: Self.calendar
        )

        #expect(listing.transcripts.isEmpty)
        #expect(listing.counts.transcripts == 0)
    }

    /// The chips split the answer by kind, which is Finder's scope bar over a folder of results.
    @Test("the Workspaces and Transcripts chips each show one half")
    func theSearchChipsSplitTheAnswer() {
        let now = date(2025, 8, 19, 12, 0, 0)
        func listing(_ scope: HomeScope) -> HomeListing {
            HomeList.build(
                repos: [repo("repo", name: "Bloom")],
                workspaces: [workspace("sidebar rewrite", at: now)],
                archived: [],
                transcripts: [transcriptResult("sidebar rewrite", matches: 4)],
                filter: HomeFilter(query: "sidebar", scope: scope),
                now: now,
                calendar: Self.calendar
            )
        }

        #expect(listing(.all).groups.count == 1)
        #expect(listing(.all).transcripts.count == 1)
        #expect(listing(.workspaces).groups.count == 1)
        #expect(listing(.workspaces).transcripts.isEmpty)
        #expect(listing(.transcripts).groups.isEmpty)
        #expect(listing(.transcripts).transcripts.count == 1)
    }

    /// The Archived chip means finished WORK, not finished workspaces, so it holds the transcripts
    /// of archived workspaces as well as their rows, and nothing a live agent said.
    @Test("the Archived chip narrows both halves of a search")
    func archivedNarrowsBothHalves() {
        let now = date(2025, 8, 19, 12, 0, 0)
        let listing = HomeList.build(
            repos: [repo("repo", name: "Bloom")],
            workspaces: [workspace("sidebar live", at: now)],
            archived: [workspace("sidebar gone", at: now, state: .archived)],
            transcripts: [
                transcriptResult("sidebar live", matches: 5),
                transcriptResult("sidebar gone", matches: 2),
            ],
            filter: HomeFilter(query: "sidebar", scope: .archived),
            now: now,
            calendar: Self.calendar
        )

        #expect(listing.groups.flatMap(\.rows).map(\.id.rawValue) == ["sidebar gone"])
        #expect(listing.transcripts.map(\.workspaceID.rawValue) == ["sidebar gone"])
        // One archived row plus the two matches inside it, which is the same unit "Everything"
        // counts in: one workspace hit plus one archived hit plus seven matches.
        #expect(listing.counts.archived == 3)
        #expect(listing.counts.count(of: .all, searching: true) == 9)
    }

    /// Outside a search the index is not asked, so anything left over from the last one must not
    /// be drawn under a list of everything on the machine.
    @Test("transcript results are dropped the moment the field is empty")
    func transcriptsGoWhenTheFieldIsCleared() {
        let now = date(2025, 8, 19, 12, 0, 0)
        let listing = HomeList.build(
            repos: [repo("repo")],
            workspaces: [workspace("here", at: now)],
            archived: [],
            transcripts: [transcriptResult("here", matches: 4)],
            filter: HomeFilter(),
            now: now,
            calendar: Self.calendar
        )

        #expect(!listing.isSearching)
        #expect(listing.transcripts.isEmpty)
    }

    /// A search that found transcripts and no names is not an empty pane, and raising the empty
    /// state over it would hide the answer.
    @Test("a search with transcript hits and no name hits is not empty")
    func transcriptsAloneAreNotEmpty() {
        let now = date(2025, 8, 19, 12, 0, 0)
        let listing = HomeList.build(
            repos: [repo("repo")],
            workspaces: [workspace("quiet", at: now)],
            archived: [],
            transcripts: [transcriptResult("quiet", matches: 4)],
            filter: HomeFilter(query: "sidebar", scope: .all),
            now: now,
            calendar: Self.calendar
        )

        #expect(listing.groups.isEmpty)
        #expect(!listing.isEmpty)
    }

    /// Two counts because one of them alone misleads: "37 matches" over nine workspaces reads as a
    /// very long list, and "9 workspaces" hides that most of them matched once.
    @Test("the transcript heading counts matches and workspaces, and pluralises both")
    func theTranscriptHeadingCountsBoth() {
        #expect(
            HomeList.transcriptHeading([transcriptResult("a", matches: 37)])
                == "In transcripts \u{00B7} 37 matches in 1 workspace"
        )
        #expect(
            HomeList.transcriptHeading([
                transcriptResult("a", matches: 1), transcriptResult("b", matches: 2),
            ]) == "In transcripts \u{00B7} 3 matches in 2 workspaces"
        )
        #expect(
            HomeList.transcriptHeading([transcriptResult("a", matches: 1)])
                == "In transcripts \u{00B7} 1 match in 1 workspace"
        )
    }
}
