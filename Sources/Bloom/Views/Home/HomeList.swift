import Foundation
import BloomCore

/// One line of Home's list: a workspace, and the project it belongs to.
///
/// The project travels with the row because Home is flat. In the sidebar a workspace sits under
/// its project's heading and needs no mark of its own; here every row is a different project's,
/// and looking the repository up per row while drawing would be a linear scan of the project list
/// once per visible row.
struct HomeRow: Identifiable, Hashable {
    var workspace: Workspace
    var repo: Repo?

    var id: String { workspace.id }

    var isArchived: Bool { workspace.state != .active }
}

/// One date heading and the rows under it.
struct HomeGroup: Identifiable, Hashable {
    /// Stable across redraws and unique per bucket, so the list keeps its scroll position when a
    /// diff stat updates. Deliberately not the title: two different months would collide on
    /// "August" once the year rolls over.
    var id: String
    var title: String
    var rows: [HomeRow]
}

/// What Home is showing, and enough about what it is not showing to explain itself.
///
/// The counts are the reason this is one value rather than an array of groups. Four different
/// empty screens are reachable (nothing exists, nothing matches the search, nothing is in the
/// chosen projects, everything is archived and archived is hidden), and telling them apart from
/// an empty array alone is impossible.
struct HomeListing {
    var groups: [HomeGroup]
    /// Rows in the list, after every filter.
    var shown: Int
    /// Workspaces the filters were applied to, archived ones included only when they are on.
    var considered: Int
    /// Archived workspaces that exist, whether or not they are being shown.
    var archived: Int
    /// Rows in the list that are archived.
    var shownArchived: Int

    static let empty = HomeListing(
        groups: [], shown: 0, considered: 0, archived: 0, shownArchived: 0
    )

    var isEmpty: Bool { groups.isEmpty }
}

/// The filter Home's controls add up to.
struct HomeFilter: Equatable {
    var query = ""
    /// Empty means every project. A set rather than an optional so "all" and "none chosen" are
    /// the same state, which is what stops the menu from reaching a configuration that shows
    /// nothing and offers no way back.
    var projects: Set<String> = []
    var showsArchived = false

    var isNarrowed: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || !projects.isEmpty
    }
}

/// Everything Home's list is worked out by, in one pass, with no view involved.
///
/// It is pure and static on purpose. The filtering, the recency order and the date buckets are the
/// whole judgement Home makes, and a judgement that lives inside a `body` can only be checked by
/// taking a screenshot of it. It also runs over every workspace on the machine, which is hundreds
/// of rows on a real install, so it is called when its inputs change rather than while drawing.
enum HomeList {
    static func build(
        repos: [Repo],
        workspaces: [Workspace],
        archived: [Workspace],
        filter: HomeFilter,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> HomeListing {
        var byID: [String: Repo] = [:]
        byID.reserveCapacity(repos.count)
        for repo in repos { byID[repo.id] = repo }

        let needle = filter.query.trimmingCharacters(in: .whitespaces).lowercased()
        var considered = 0
        var rows: [HomeRow] = []
        rows.reserveCapacity(workspaces.count)

        func consider(_ workspace: Workspace) {
            considered += 1
            if !filter.projects.isEmpty, !filter.projects.contains(workspace.repoID) { return }
            let repo = byID[workspace.repoID]
            guard matches(workspace, repo: repo, needle: needle) else { return }
            rows.append(HomeRow(workspace: workspace, repo: repo))
        }

        for workspace in workspaces { consider(workspace) }
        if filter.showsArchived {
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

    /// The same three fields `AppModel.search` matches, so a workspace that Home's field finds is
    /// one the Search screen would find too. Two search rules over one list is a bug report.
    private static func matches(_ workspace: Workspace, repo: Repo?, needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        if workspace.name.lowercased().contains(needle) { return true }
        if workspace.branch.lowercased().contains(needle) { return true }
        if let repo, repo.name.lowercased().contains(needle) { return true }
        return false
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
    struct Bucket: Hashable {
        var id: String
        var title: String
    }

    /// Fine near today and coarse further back, because that is how the question changes. Within
    /// the last week the user is asking which day; a month out they are asking which month, and
    /// twenty separate "23 days ago" headings would be a list of headings rather than of work.
    static func bucket(for date: Date, now: Date, calendar: Calendar) -> Bucket {
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
            title: year == current.year
                ? day.formatted(.dateTime.month(.wide))
                : day.formatted(.dateTime.month(.wide).year())
        )
    }
}

/// How long ago, in the two or three characters a dense row has room for.
///
/// Hand written rather than `Date.RelativeFormatStyle`, whose shortest form is still "1d ago".
/// Under a heading that already says "2 days ago", the word "ago" is on every row of the group
/// saying nothing, and the trailing column has to be narrow enough to leave the name its width.
enum HomeAge {
    static func short(for date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }

        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }

        let days = hours / 24
        if days < 7 { return "\(days)d" }

        let weeks = days / 7
        if weeks < 5 { return "\(weeks)w" }

        let months = days / 30
        if months < 12 { return "\(months)mo" }

        return "\(days / 365)y"
    }
}
