import Foundation

/// One line of Home's list: a workspace, and the project it belongs to.
///
/// The project travels with the row because Home is flat. In the sidebar a workspace sits under
/// its project's heading and needs no mark of its own; here every row is a different project's,
/// and looking the repository up per row while drawing would be a linear scan of the project list
/// once per visible row.
public struct HomeRow: Identifiable, Hashable, Sendable {
    public var workspace: Workspace
    public var repo: Repo?
    /// The text that put this row in a search, when it was not the name.
    ///
    /// `WorkspaceSearch.match` searches the name, the branch and the project, so a row can be a
    /// perfect answer with nothing on it that looks like what was typed: searching a branch name
    /// used to produce a list of workspaces with no visible connection to the query at all. The
    /// row says which field answered instead.
    ///
    /// Nil outside a search, and nil when the name itself matched, because then the row is already
    /// showing it.
    public var match: String?

    public init(workspace: Workspace, repo: Repo? = nil, match: String? = nil) {
        self.workspace = workspace
        self.repo = repo
        self.match = match
    }

    public var id: WorkspaceID { workspace.id }

    public var isArchived: Bool { workspace.state != .active }
}

/// One date heading and the rows under it.
public struct HomeGroup: Identifiable, Hashable, Sendable {
    /// Stable across redraws and unique per bucket, so the list keeps its scroll position when a
    /// diff stat updates. Deliberately not the title: two different months would collide on
    /// "August" once the year rolls over.
    public var id: String
    public var title: String
    public var rows: [HomeRow]

    public init(id: String, title: String, rows: [HomeRow]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}

/// What Home is showing, and enough about what it is not showing to explain itself.
///
/// The counts are the reason this is one value rather than an array of groups. Several different
/// empty screens are reachable (nothing exists, nothing matches the search, nothing is in the
/// chosen projects, nothing is in the chosen scope), and telling them apart from an empty array
/// alone is impossible. `counts` is the other half of it: every chip on the strip carries its own
/// number, and they are worked out in this one pass rather than in five more.
public struct HomeListing: Sendable {
    public var groups: [HomeGroup]
    /// The transcripts that matched, one entry per workspace. Empty outside a search, because the
    /// index is only asked when there is something to ask it.
    public var transcripts: [TranscriptWorkspaceMatches]
    public var counts: HomeScopeCounts
    /// Whether the field has something in it, which decides both which chips are offered and
    /// whether the rows are bucketed by date or gathered under one heading.
    public var isSearching: Bool
    /// Workspace rows in the list, after every filter.
    public var shown: Int
    /// Workspaces the filters were applied to, archived ones included.
    public var considered: Int
    /// Archived workspaces that exist, whether or not they are being shown.
    public var archived: Int
    /// Rows in the list that are archived.
    public var shownArchived: Int

    public init(
        groups: [HomeGroup],
        transcripts: [TranscriptWorkspaceMatches] = [],
        counts: HomeScopeCounts = HomeScopeCounts(),
        isSearching: Bool = false,
        shown: Int,
        considered: Int,
        archived: Int,
        shownArchived: Int
    ) {
        self.groups = groups
        self.transcripts = transcripts
        self.counts = counts
        self.isSearching = isSearching
        self.shown = shown
        self.considered = considered
        self.archived = archived
        self.shownArchived = shownArchived
    }

    public static let empty = HomeListing(
        groups: [], shown: 0, considered: 0, archived: 0, shownArchived: 0
    )

    /// Nothing in the pane at all, which is what raises the empty state. A search that found
    /// transcripts and no names is not empty, so both halves are asked.
    public var isEmpty: Bool { groups.isEmpty && transcripts.isEmpty }
}

/// The filter Home's controls add up to: the window's search field, the chips and the project
/// menu.
public struct HomeFilter: Equatable, Sendable {
    /// What was typed into the window's search field.
    ///
    /// One query, not two. Home had a field of its own and the Search screen had another; both
    /// matched by the same rule, drew the answer two different ways and kept two keyboard models
    /// alive to walk them.
    public var query = ""
    /// Empty means every project. A set rather than an optional so "all" and "none chosen" are
    /// the same state, which is what stops the menu from reaching a configuration that shows
    /// nothing and offers no way back.
    public var projects: Set<RepoID> = []
    /// Which chip is lit. `all` includes archived work, so nothing on this Mac is hidden behind a
    /// control somebody has to remember to check.
    ///
    /// This replaced a "Hide archived" switch, and `HomeScope.live` is what that switch did. A
    /// scope rather than a switch of its own, because the switch was a second narrowing mechanism
    /// beside the field with its own state, its own empty state and its own clause in the summary
    /// line, all to answer a question the chips answer with a number attached.
    public var scope: HomeScope = .all

    public init(query: String = "", projects: Set<RepoID> = [], scope: HomeScope = .all) {
        self.query = query
        self.projects = projects
        self.scope = scope
    }

    /// What was typed, trimmed and lowercased, which is what every match here is made against.
    public var needle: String { WorkspaceSearch.needle(query) }

    public var isSearching: Bool { !needle.isEmpty }

    /// Whether the list is a subset of what was counted, which is what makes the readout say
    /// "Showing 11 of 312" rather than a bare total.
    ///
    /// The scope is deliberately not part of this, for the reason hiding archived was not part of
    /// it before: every chip carries its own count an inch to the left of this readout, so a
    /// scope that narrows the list is already saying so, with a number the shown-of-considered
    /// pair cannot carry.
    public var isNarrowed: Bool {
        isSearching || !projects.isEmpty
    }
}

/// Everything Home's list is worked out by, in one pass, with no view involved.
///
/// It is pure and static on purpose. The filtering, the recency order and the date buckets are the
/// whole judgement Home makes, and a judgement that lives inside a `body` can only be checked by
/// taking a screenshot of it. It also runs over every workspace on the machine, which is hundreds
/// of rows on a real install, so it is called when its inputs change rather than while drawing.
///
/// It lives in the core rather than beside the view for the same reason: date bucketing and
/// relative ages are exactly the arithmetic that goes wrong by one at a boundary, and the app
/// target has no test target of its own. Every date input is injected, so the suite can stand a
/// workspace either side of midnight without waiting for midnight.
public enum HomeList {
    /// - Parameters:
    ///   - transcripts: what the full text index said about the query, which arrives from the
    ///     store a moment after the names do and is empty until it has. It is passed in rather
    ///     than fetched, because this runs on every keystroke over an array already in memory and
    ///     the index query is a hop onto the store actor.
    ///   - activity: which agents are running and which have stopped to ask, so the "Needs you"
    ///     and "Running" chips can be counted here rather than by the view.
    public static func build(
        repos: [Repo],
        workspaces: [Workspace],
        archived: [Workspace],
        transcripts: [TranscriptWorkspaceMatches] = [],
        filter: HomeFilter,
        activity: HomeActivity = HomeActivity(),
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> HomeListing {
        var byID: [RepoID: Repo] = [:]
        byID.reserveCapacity(repos.count)
        for repo in repos { byID[repo.id] = repo }

        let needle = filter.needle
        let isSearching = filter.isSearching
        var considered = 0
        var counts = HomeScopeCounts()
        // Everything the project filter and the query let through, before the chip is applied.
        // The chips have to count what clicking them WOULD show, so a chip's own narrowing is
        // never in its own number.
        var matched: [HomeRow] = []
        matched.reserveCapacity(workspaces.count)

        func consider(_ workspace: Workspace) {
            considered += 1
            if !filter.projects.isEmpty, !filter.projects.contains(workspace.repoID) { return }
            let repo = byID[workspace.repoID]
            let field = WorkspaceSearch.match(workspace: workspace, repo: repo, needle: needle)
            guard !isSearching || field != nil else { return }
            let row = HomeRow(
                workspace: workspace,
                repo: repo,
                // Only when it was not the name, which the row already draws.
                match: field == workspace.name ? nil : field
            )
            matched.append(row)
            if row.isArchived { counts.archived += 1 } else { counts.live += 1 }
            if activity.needsYou(workspace) { counts.needsYou += 1 }
            if activity.isRunning(workspace) { counts.running += 1 }
        }

        for workspace in workspaces { consider(workspace) }
        for workspace in archived { consider(workspace) }
        counts.workspaces = matched.count

        let archivedIDs = Set(archived.map(\.id))
        let hits = transcriptHits(
            transcripts,
            isSearching: isSearching,
            projects: filter.projects,
            workspaces: workspaces,
            archived: archived
        )
        for hit in hits {
            counts.transcripts += hit.total
            counts.transcriptWorkspaces += 1
            if archivedIDs.contains(hit.workspaceID) { counts.archived += hit.total }
        }

        let rows = matched.filter { filter.scope.includes($0, activity: activity) }
        let shownTranscripts = isSearching
            ? hits.filter {
                filter.scope.includesTranscript(isArchived: archivedIDs.contains($0.workspaceID))
            }
            : []

        // Recency, most recent first, and nothing else. Pinning is the sidebar's ordering, and a
        // pinned workspace from three weeks ago hoisted to the top would land under a "Today"
        // heading that is then a lie.
        let ordered = filter.scope.showsWorkspaces
            ? rows.sorted { $0.workspace.lastActivityAt > $1.workspace.lastActivityAt }
            : []

        // Searching, the date buckets go. A result list ordered by when the work last happened,
        // under headings that say "3 weeks ago", answers a question nobody asked: what was typed
        // is the question, and the heading over the answer says which KIND of thing matched. It
        // is still one `HomeGroup` in one `List`, which is what keeps the arrow keys and Return
        // working with one keyboard model rather than two.
        let groups = isSearching
            ? (ordered.isEmpty ? [] : [HomeGroup(id: "workspaces", title: "Workspaces", rows: ordered)])
            : group(ordered, now: now, calendar: calendar)

        return HomeListing(
            groups: groups,
            transcripts: shownTranscripts,
            counts: counts,
            isSearching: isSearching,
            shown: ordered.count,
            considered: considered,
            archived: archived.count,
            shownArchived: ordered.count { $0.isArchived }
        )
    }

    /// The transcript results the project menu leaves standing.
    ///
    /// The store answers about every workspace on the machine, so the project filter has to be
    /// applied here or a list narrowed to one project would still show what the agents said in
    /// the others. A result whose workspace is in neither list is dropped rather than kept
    /// unfiltered: it has been deleted since the index was written, and there is nothing to open.
    private static func transcriptHits(
        _ transcripts: [TranscriptWorkspaceMatches],
        isSearching: Bool,
        projects: Set<RepoID>,
        workspaces: [Workspace],
        archived: [Workspace]
    ) -> [TranscriptWorkspaceMatches] {
        guard isSearching, !transcripts.isEmpty else { return [] }
        var repoOf: [WorkspaceID: RepoID] = [:]
        for workspace in workspaces { repoOf[workspace.id] = workspace.repoID }
        for workspace in archived { repoOf[workspace.id] = workspace.repoID }

        return transcripts.filter { result in
            guard let repoID = repoOf[result.workspaceID] else { return false }
            return projects.isEmpty || projects.contains(repoID)
        }
    }

    /// The heading over the transcript results, which counts two things because one of them alone
    /// misleads: "37 matches" over nine workspaces reads as a very long list, and "9 workspaces"
    /// hides that most of them matched once.
    public static func transcriptHeading(_ results: [TranscriptWorkspaceMatches]) -> String {
        let matches = results.reduce(0) { $0 + $1.total }
        return "In transcripts \u{00B7} \(ArchiveDeletion.count(matches, "match", plural: "matches")) "
            + "in \(ArchiveDeletion.count(results.count, "workspace"))"
    }

    /// Walks the sorted rows once and starts a new group whenever the bucket changes. No sorting
    /// of the groups themselves: rows are already in recency order, so the buckets come out in it.
    private static func group(
        _ rows: [HomeRow],
        now: Date,
        calendar: Calendar
    ) -> [HomeGroup] {
        var groups: [HomeGroup] = []

        for row in rows {
            let bucket = bucket(for: row.workspace.lastActivityAt, now: now, calendar: calendar)
            if groups.last?.id == bucket.id {
                groups[groups.count - 1].rows.append(row)
            } else {
                groups.append(HomeGroup(id: bucket.id, title: bucket.title, rows: [row]))
            }
        }

        return groups
    }

    /// A date heading: what it is called, and the key that decides where one group ends.
    public struct Bucket: Hashable, Sendable {
        public var id: String
        public var title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// Fine near today and coarse further back, because that is how the question changes. Within
    /// the last week the user is asking which day; a month out they are asking which month, and
    /// twenty separate "23 days ago" headings would be a list of headings rather than of work.
    ///
    /// Counted in calendar days in the user's own time zone rather than in elapsed hours. Half
    /// past eleven last night and half past midnight this morning are an hour apart and belong
    /// under two different headings, because "yesterday" is a thing the calendar decides.
    public static func bucket(for date: Date, now: Date, calendar: Calendar) -> Bucket {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0

        // A workspace whose activity is stamped in the future, which a clock change or a machine
        // restored from a backup will produce, belongs at the top rather than in a heading that
        // says "-1 days ago".
        if days <= 0 { return Bucket(id: "day-0", title: "Today") }
        if days == 1 { return Bucket(id: "day-1", title: "Yesterday") }
        if days < 7 { return Bucket(id: "day-\(days)", title: "\(days) days ago") }

        if days < 28 {
            let weeks = days / 7
            return Bucket(
                id: "week-\(weeks)",
                title: weeks == 1 ? "Last week" : "\(weeks) weeks ago"
            )
        }

        let parts = calendar.dateComponents([.year, .month], from: day)
        let current = calendar.dateComponents([.year, .month], from: today)
        let year = parts.year ?? 0
        let month = parts.month ?? 0

        // Reachable at the end of a long month: 29 days back can still be the first of this one.
        if year == current.year, month == current.month {
            return Bucket(id: "month-\(year)-\(month)", title: "Earlier this month")
        }

        return Bucket(
            id: "month-\(year)-\(month)",
            title: monthName(of: day, calendar: calendar, includingYear: year != current.year)
        )
    }

    /// The month heading, spelled in the same calendar the bucket was worked out in.
    ///
    /// The calendar is pushed into the format style rather than left to the process default. The
    /// two are the same thing on a running Mac, but a caller that hands in a calendar in another
    /// time zone would otherwise get an id worked out in one zone and a title worked out in
    /// another, and on the first or last day of a month those name two different months.
    private static func monthName(
        of day: Date, calendar: Calendar, includingYear: Bool
    ) -> String {
        var style = includingYear
            ? Date.FormatStyle.dateTime.month(.wide).year()
            : Date.FormatStyle.dateTime.month(.wide)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        // The month is still spelled in the caller's language: `Calendar.current` carries the
        // user's locale, so nothing about the running app changes.
        if let locale = calendar.locale { style.locale = locale }
        return day.formatted(style)
    }

    /// The line above the list, which describes the list rather than the database.
    ///
    /// A line reading "312 workspaces" above eleven rows is how a forgotten filter becomes a bug
    /// report about missing work, so a narrowed list says so in the same breath as the total it
    /// was narrowed from.
    ///
    /// **It was four pieces of view state picking between sentences inside `HomeView`, and the
    /// comment on its first clause records that the expression had already produced a wrong
    /// answer once**: "0 workspaces" about a machine holding three, printed directly above a
    /// panel saying all three existed. That is the whole argument for this being here. A sentence
    /// assembled in a body is a sentence nothing can be asked about, and this one has five
    /// branches and four counts.
    ///
    /// Empty when there is nothing to describe. The strip is not drawn then, and on a machine
    /// with no project there is nothing to count.
    ///
    /// **It says less than it used to, and that is the point.** It used to carry the archived
    /// count and the running count as trailing clauses, because nothing else on the strip did.
    /// Both of those are chips now, with their own numbers, six inches to the left of this
    /// sentence, so repeating them here was the same fact printed twice on one line.
    public static func summary(
        listing: HomeListing,
        filter: HomeFilter,
        projects: Int
    ) -> String {
        guard listing.considered > 0 || listing.archived > 0 else { return "" }

        // Searching, the only fact worth carrying is how many answers came back, because the
        // chips beside it have already split them by kind.
        if listing.isSearching {
            let found = listing.counts.count(of: filter.scope, searching: true)
            return "\(ArchiveDeletion.count(found, "result")) for \u{201C}\(filter.query.trimmingCharacters(in: .whitespaces))\u{201D}"
        }

        if filter.isNarrowed {
            return "Showing \(listing.shown) of \(ArchiveDeletion.count(listing.considered, "workspace"))"
        }

        // What the machine holds, in the two halves the chips do not repeat: how it is spread
        // over projects, and how much of it is finished. "48 workspaces" reads very differently
        // once you know 30 of them are over.
        var text = projects > 1
            ? ArchiveDeletion.count(projects, "project")
            : ArchiveDeletion.count(listing.considered, "workspace")

        if projects > 1 {
            text += " \u{00B7} \(listing.counts.live) live"
        } else if listing.counts.archived > 0 {
            text += ", \(listing.counts.live) live"
        }

        if listing.counts.archived > 0 {
            text += ", \(listing.counts.archived) archived"
        }

        return text
    }
}

/// How long ago, in the two or three characters a dense row has room for.
///
/// Hand written rather than `Date.RelativeFormatStyle`, whose shortest form is still "1d ago".
/// Under a heading that already says "2 days ago", the word "ago" is on every row of the group
/// saying nothing, and the trailing column has to be narrow enough to leave the name its width.
public enum HomeAge {
    public static func short(for date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        // Also catches a timestamp from the future, which a clock change or a restore from backup
        // produces. "now" is the least wrong thing to say about it, and it is what the "Today"
        // bucket such a row lands in already implies.
        if seconds < 60 { return "now" }

        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }

        let days = hours / 24
        if days < 7 { return "\(days)d" }

        let weeks = days / 7
        if weeks < 5 { return "\(weeks)w" }

        // Gated on whole years rather than on `days / 30 < 12`. Thirty-day months run ahead of the
        // calendar, so a year is reached at day 360 by that reckoning and at day 365 by this one:
        // the five days in between fell through to the year branch and printed "0y".
        let years = days / 365
        if years < 1 { return "\(days / 30)mo" }

        return "\(years)y"
    }

    /// The same age with the word on it, for somewhere that has room for the word.
    ///
    /// Home's rows do not: they are a dense list under a heading that already says "2 days ago",
    /// so "ago" on every row of the group says nothing. A card that opens beside one row is the
    /// opposite case, and "6d" alone there reads as a measurement rather than as a time.
    ///
    /// Built on `short` rather than beside it, which is the whole reason it is here and not in
    /// the card. Every threshold, and the future-dated timestamp a clock change produces, is
    /// decided once. The one thing it cannot pass through is "now", because "now ago" is not
    /// English.
    public static func phrase(for date: Date, now: Date = Date()) -> String {
        let age = short(for: date, now: now)
        return age == "now" ? "just now" : "\(age) ago"
    }
}
