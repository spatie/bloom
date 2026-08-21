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

    public init(workspace: Workspace, repo: Repo? = nil) {
        self.workspace = workspace
        self.repo = repo
    }

    public var id: String { workspace.id }

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
/// The counts are the reason this is one value rather than an array of groups. Four different
/// empty screens are reachable (nothing exists, nothing matches the search, nothing is in the
/// chosen projects, everything is archived and archived is hidden), and telling them apart from
/// an empty array alone is impossible.
public struct HomeListing: Sendable {
    public var groups: [HomeGroup]
    /// Rows in the list, after every filter.
    public var shown: Int
    /// Workspaces the filters were applied to, archived ones included unless they are being
    /// hidden.
    public var considered: Int
    /// Archived workspaces that exist, whether or not they are being shown.
    public var archived: Int
    /// Rows in the list that are archived.
    public var shownArchived: Int

    public init(
        groups: [HomeGroup], shown: Int, considered: Int, archived: Int, shownArchived: Int
    ) {
        self.groups = groups
        self.shown = shown
        self.considered = considered
        self.archived = archived
        self.shownArchived = shownArchived
    }

    public static let empty = HomeListing(
        groups: [], shown: 0, considered: 0, archived: 0, shownArchived: 0
    )

    public var isEmpty: Bool { groups.isEmpty }
}

/// The filter Home's controls add up to.
public struct HomeFilter: Equatable, Sendable {
    public var query = ""
    /// Empty means every project. A set rather than an optional so "all" and "none chosen" are
    /// the same state, which is what stops the menu from reaching a configuration that shows
    /// nothing and offers no way back.
    public var projects: Set<RepoID> = []
    /// Whether archived workspaces are being kept OUT of the list. Off by default, so Home opens
    /// on everything on the machine.
    ///
    /// It was the other way round, `showsArchived`, defaulting to off, and the inversion is not a
    /// rename. Home is the flat list of every workspace on this Mac and it is the only screen that
    /// lists an archived one at all, so a default that hid them meant the one place they could be
    /// found never showed them until you knew to ask. Turning the default around leaves a switch
    /// that only ever adds rows nobody hid, which is a control with no job, so it became the
    /// narrowing it now is: a way to put a machine with two hundred finished workspaces back down
    /// to the ones still being worked in.
    public var hidesArchived = false

    public init(query: String = "", projects: Set<RepoID> = [], hidesArchived: Bool = false) {
        self.query = query
        self.projects = projects
        self.hidesArchived = hidesArchived
    }

    /// Whether the list is a subset of what was counted, which is what makes the readout say
    /// "Showing 11 of 312" rather than a bare total.
    ///
    /// Hiding archived narrows the list too, and is deliberately not part of this. The two things
    /// `isNarrowed` drives both compare `shown` against `considered`, and a hidden archived
    /// workspace is never considered in the first place, so it would produce "Showing 11 of 11".
    /// It is reported by the clause that says how many archived rows are being held back instead,
    /// which is a number the shown-of-considered pair cannot carry.
    public var isNarrowed: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || !projects.isEmpty
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
    public static func build(
        repos: [Repo],
        workspaces: [Workspace],
        archived: [Workspace],
        filter: HomeFilter,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> HomeListing {
        var byID: [RepoID: Repo] = [:]
        byID.reserveCapacity(repos.count)
        for repo in repos { byID[repo.id] = repo }

        let needle = WorkspaceSearch.needle(filter.query)
        var considered = 0
        var rows: [HomeRow] = []
        rows.reserveCapacity(workspaces.count)

        func consider(_ workspace: Workspace) {
            considered += 1
            if !filter.projects.isEmpty, !filter.projects.contains(workspace.repoID) { return }
            let repo = byID[workspace.repoID]
            guard WorkspaceSearch.matchesOrIsUnfiltered(
                workspace: workspace, repo: repo, needle: needle
            ) else { return }
            rows.append(HomeRow(workspace: workspace, repo: repo))
        }

        for workspace in workspaces { consider(workspace) }
        if !filter.hidesArchived {
            for workspace in archived { consider(workspace) }
        }

        // Recency, most recent first, and nothing else. Pinning is the sidebar's ordering, and a
        // pinned workspace from three weeks ago hoisted to the top would land under a "Today"
        // heading that is then a lie.
        rows.sort { $0.workspace.lastActivityAt > $1.workspace.lastActivityAt }

        return HomeListing(
            groups: group(rows, now: now, calendar: calendar),
            shown: rows.count,
            considered: considered,
            archived: archived.count,
            shownArchived: rows.count { $0.isArchived }
        )
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
}
