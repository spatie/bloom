import BatonCore

/// Which of Home's questions a workspace is an answer to.
///
/// Three lanes rather than thirteen states, because Home is read from across the room: the user
/// wants to know whether anything is burning, whether anything is moving, and whether the rest can
/// be ignored. The thirteen states stay the source of truth and are still drawn on every card; this
/// only says which pile each of them falls into.
enum HomeLane {
    /// A machine is busy in it right now, so there is nothing to do but watch.
    case working
    /// It has stopped and cannot move again until a person does something.
    case waiting
    /// Nothing is asking for anything.
    case resting
}

extension WorkspaceStatus {
    var homeLane: HomeLane {
        switch self {
        case .settingUp, .running, .checksRunning: .working
        case .setupFailed, .unread, .checksFailing, .checksPassed, .merged, .closed: .waiting
        case .draft, .pullRequestOpen, .changed, .clean: .resting
        }
    }

    /// Where this verdict sits in `WorkspaceStatus`'s own precedence chain, which is already an
    /// ordering from most to least urgent. Home sorts by it rather than inventing a second opinion
    /// about what is interesting, so a card cannot rank above another one while wearing a calmer
    /// mark than it.
    var homeUrgency: Int { Self.urgencies[self] ?? Self.allCases.count }

    /// `allCases` is synthesised, so it builds a fresh array on every access. Home asks this once
    /// per workspace per pass and the pass runs while agents are streaming.
    private static let urgencies: [WorkspaceStatus: Int] = Dictionary(
        uniqueKeysWithValues: allCases.enumerated().map { ($0.element, $0.offset) }
    )
}

/// What one workspace amounts to: the state, and the sentence that state deserves.
///
/// The two travel together because the sentence is not derivable from the state alone. "Checks
/// failing" cannot say "1 required check failed", and that number is the entire reason someone
/// hovers the mark, so `WorkspaceStatus.summary(pullRequest:)` folds GitHub's own wording in and
/// the result is carried rather than recomputed from a pull request the card never sees.
struct HomeVerdict {
    var status: WorkspaceStatus
    var summary: String
}

/// One workspace on Home, together with the verdict that decides where it sorts and what mark it
/// carries. Resolved once per pass so a card, its tooltip and the lane it was filed under cannot
/// disagree about what it is.
struct HomeWorkspace: Identifiable, Hashable {
    var workspace: Workspace
    var status: WorkspaceStatus
    /// What the mark means, in one sentence, for the tooltip and for VoiceOver. Both get the same
    /// words on purpose: a sighted user hovering and a VoiceOver user landing on the card are
    /// asking the identical question.
    var summary: String
    /// Only set where the card is drawn away from its own project's block, which is the one place
    /// the project name is not already on screen directly above it.
    var repo: Repo?

    var id: String { workspace.id }
}

/// One project's block: the cards it shows, and the totals that describe the ones it does not.
struct HomeProject: Identifiable {
    var repo: Repo
    var shown: [HomeWorkspace]
    var total: Int
    var runningCount: Int
    var additions: Int
    var deletions: Int

    var id: String { repo.id }

    var isTruncated: Bool { total > shown.count }
}

/// Everything Home draws, worked out in one pass over the workspace list.
///
/// It is a plain value built by a static function rather than logic scattered through view bodies,
/// for two reasons. The sums, the lanes and the caps are the actual judgement Home makes, and a
/// judgement that lives in a `body` can only be checked by taking a screenshot of it. And Home is
/// on screen while agents are streaming, so anything it does runs several times a second: one
/// grouped pass costs a fraction of what the per-project filtering it replaced did.
struct HomeDigest {
    var projects: [HomeProject]
    /// The cross-project shortlist, most urgent first. Empty unless the lane is worth drawing.
    var attention: [HomeWorkspace]
    var workspaceCount: Int
    var projectCount: Int
    var runningCount: Int
    var settingUpCount: Int
    var waitingCount: Int

    /// How many cards one project shows before the rest are left to the sidebar, which is the
    /// complete list and always beside this one. The single-project case gets a longer grid because
    /// there is nothing else on the screen competing for the height.
    private static func cap(projectsWithWork: Int) -> Int {
        projectsWithWork > 1 ? 6 : 12
    }

    /// Long enough to be a shortlist, short enough that it cannot itself become the wall it exists
    /// to save the user from scanning.
    private static let attentionCap = 6

    static func build(
        repos: [Repo],
        workspaces: [Workspace],
        verdict: (Workspace) -> HomeVerdict
    ) -> HomeDigest {
        var byRepo: [String: [HomeWorkspace]] = [:]
        var running = 0
        var settingUp = 0
        var waiting = 0

        for workspace in workspaces {
            let resolved = verdict(workspace)
            switch resolved.status {
            case .running: running += 1
            case .settingUp: settingUp += 1
            default: break
            }
            if resolved.status.homeLane == .waiting { waiting += 1 }
            byRepo[workspace.repoID, default: []].append(
                HomeWorkspace(
                    workspace: workspace,
                    status: resolved.status,
                    summary: resolved.summary
                )
            )
        }

        let populated = repos.filter { byRepo[$0.id]?.isEmpty == false }
        let cap = cap(projectsWithWork: populated.count)

        let projects = populated.map { repo in
            let rows = (byRepo[repo.id] ?? []).sorted(by: precedes)
            return HomeProject(
                repo: repo,
                shown: Array(rows.prefix(cap)),
                total: rows.count,
                runningCount: rows.count { $0.status == .running },
                additions: rows.reduce(0) { $0 + $1.workspace.additions },
                deletions: rows.reduce(0) { $0 + $1.workspace.deletions }
            )
        }

        return HomeDigest(
            projects: projects,
            attention: attention(in: byRepo, repos: populated),
            workspaceCount: workspaces.count,
            projectCount: repos.count,
            runningCount: running,
            settingUpCount: settingUp,
            waitingCount: waiting
        )
    }

    /// The shortlist, and the rule for when there is one at all.
    ///
    /// Its whole job is to save a scan across several project blocks. With one project its block is
    /// already the entire list, sorted the same way, so a lane above it would be a copy of the rows
    /// three centimetres below it rather than a shortcut to them.
    private static func attention(
        in byRepo: [String: [HomeWorkspace]],
        repos: [Repo]
    ) -> [HomeWorkspace] {
        guard repos.count > 1 else { return [] }

        let named = repos.flatMap { repo in
            (byRepo[repo.id] ?? [])
                .filter { $0.status.homeLane == .waiting }
                .map {
                    HomeWorkspace(
                        workspace: $0.workspace,
                        status: $0.status,
                        summary: $0.summary,
                        repo: repo
                    )
                }
        }
        return Array(named.sorted(by: precedes).prefix(attentionCap))
    }

    /// Urgency first, then most recently active. The tiebreak matters: a project full of workspaces
    /// that are all merely `changed` would otherwise come out in whatever order SQLite returned.
    private static func precedes(_ lhs: HomeWorkspace, _ rhs: HomeWorkspace) -> Bool {
        if lhs.status.homeUrgency != rhs.status.homeUrgency {
            return lhs.status.homeUrgency < rhs.status.homeUrgency
        }
        return lhs.workspace.lastActivityAt > rhs.workspace.lastActivityAt
    }
}
