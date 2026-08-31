import Foundation

/// Why `workspace_merge` would not ask for a merge, in terms a client can act on.
///
/// ## The misreading these are written against
///
/// `FolderRefusal.agentSentence` heads off an agent that reads "set my projects up" as permission
/// to run `git init`. The equivalent here is worse, because the thing it reaches for publishes to
/// a server other people share: **an agent reads "merge this" as permission to run `gh pr merge`
/// itself.** It has a Bash tool, `gh` is on the machine, the branch and the number are in the
/// refusal it was just handed, and every sentence below describes a state that a merge run from
/// somewhere else would have got past.
///
/// So every refusal ends with `Self.notYours`. Not as a warning about a rule, but because the
/// reason is the whole point of this tool existing: Bloom hands a merge to the workspace's own
/// agent so it happens in a chat the owner has open, with the command on screen and the permission
/// mode they set around it. A merge run anywhere else is that same merge with the only person who
/// was going to see it removed. There is nothing left to protect once a call has gone to GitHub.
///
/// ## What it will not do to be helpful
///
/// Two of these describe a state that could be "fixed" by doing something else destructive or
/// off-machine, and both say so out loud. There is no pull request: do not open one. The pull
/// request is a draft or GitHub is refusing it: do not mark it ready, do not change a check, do
/// not touch a branch protection rule.
///
/// Every sentence says whether retrying helps, names no path inside Bloom's own worktree root, and
/// quotes no command line Bloom built.
public enum WorkspaceMergeTrouble: Sendable, Equatable {
    /// The id matched nothing. `alias` is a workspace whose name or branch the caller typed
    /// instead, worked out by asking the database rather than guessing, because that is the
    /// mistake this argument invites.
    case unknownWorkspace(id: String, alias: Alias)
    /// Archived, so there is no worktree and no session left.
    case archived(workspace: String)
    /// Active, but the worktree is not on disk any more.
    case worktreeGone(workspace: String)
    /// gh could not be asked, so nothing is known about the pull request.
    case githubUnavailable(GitHubAccess)
    /// gh could be asked and did not answer. The one refusal here that is worth retrying.
    case githubSilent(String)
    /// gh answered and GitHub has no pull request for this branch.
    case noPullRequest(workspace: String, branch: String)
    /// `PullRequestStatus.canMerge` is false: merged, closed, conflicting or draft.
    case blocked(workspace: String, number: Int, headline: String, reason: String)
    /// The worktree is holding work GitHub has not got. See the case's own note below.
    case localWork(workspace: String, number: Int, detail: String, needsCommit: Bool)
    /// A message sent now would queue instead of starting a turn.
    case wouldQueue(workspace: String, hold: DeliveryHold)
    /// The app refused to send after all, in its own words. Its guard is the real gate and it is
    /// checked again on the main actor, so a turn that started between this tool's look and the
    /// send lands here rather than being sent into.
    case appRefused(String)

    /// What the caller typed, when it was not an id.
    public enum Alias: Sendable, Equatable {
        case none
        /// Exactly one workspace goes by it, and this is its id.
        case one(name: String, id: String)
        /// Several do, which is why nothing here resolves a workspace by name.
        case several(name: String, count: Int)
    }

    /// The closing line every refusal carries. See the head of this file.
    public static let notYours = "Do not run `gh pr merge` yourself to get past this, and do not "
        + "ask another agent to. Bloom sends a merge to the workspace's own agent so the owner "
        + "watches it happen; a merge run anywhere else is the same merge with nobody watching."

    /// What the caller is told, whole and on its own.
    public var sentence: String {
        (body + " " + Self.notYours)
    }

    private var body: String {
        switch self {
        case let .unknownWorkspace(id, alias):
            let opening = "Bloom has no workspace with the id '\(id)'."
            switch alias {
            case .none:
                return opening + " Call workspace_list and use the id it reports, not the name: "
                    + "two workspaces are allowed to share a name, so a name does not pick one out."
            case let .one(name, resolved):
                return opening + " '\(name)' is the NAME of a workspace Bloom has, and its id is "
                    + "'\(resolved)'. Workspaces are addressed by id here because two of them are "
                    + "allowed to share a name. Ask again with that id."
            case let .several(name, count):
                return opening + " \(count) workspaces are called '\(name)', which is exactly why "
                    + "this takes an id and not a name. Call workspace_list and pick the one you "
                    + "meant by its branch, then ask again with its id."
            }

        case .archived(let workspace):
            return """
                Bloom will not ask for a merge in '\(workspace)' because that workspace is \
                archived. Its worktree has been removed from disk and its agent is gone, so there \
                is no checkout to run a merge in and nobody to ask. Retrying will not help. If its \
                pull request is still open and should land, that is the owner's to decide.
                """

        case .worktreeGone(let workspace):
            return """
                Bloom will not ask for a merge in '\(workspace)' because its worktree is no longer \
                on disk, although Bloom still has it as an active workspace. Something moved or \
                deleted it outside Bloom. Retrying will not help. Tell the owner, and leave the \
                pull request alone until they have looked.
                """

        case .githubUnavailable(.notInstalled):
            return """
                Bloom cannot say what state that pull request is in, because `gh` is not installed \
                on this machine. It is what Bloom asks about pull requests and what the agent \
                would run to merge one, so there is nothing here that installing it around Bloom's \
                back would speed up. Retrying will not help. Tell the owner.
                """

        case .githubUnavailable(.signedOut), .githubUnavailable(.ready):
            // `.ready` cannot reach here, because a reading that got an answer is not unavailable.
            // It shares the sentence rather than being switched out, so a caller can never be told
            // nothing at all about why GitHub was not asked.
            return """
                Bloom cannot say what state that pull request is in, because `gh` is installed but \
                not signed in to GitHub. Retrying will not help until it is, and signing it in is \
                the owner's to do rather than yours: it is their account that would be merging. \
                Tell them, and say nothing about the pull request's state, because nothing was \
                read.
                """

        case .githubSilent(let message):
            // gh's own line, with exactly one full stop after it. `WorkspaceMergeTool.plainly`
            // already ends what it hands over, so a stop written here made "no git remotes found..",
            // which is what a sentence assembled out of two halves that both think they finish it
            // looks like.
            let said = message.hasSuffix(".") ? message : message + "."
            return """
                Bloom asked GitHub what state that pull request is in and gh did not answer: \
                \(said) Nothing was sent, and nothing here says anything about the pull \
                request, because nothing was read. What gh said is the whole of what is known: if \
                it reads like a network or a rate limit, asking again in a minute is the right \
                thing, and if it does not, say so rather than working round it.
                """

        case let .noPullRequest(workspace, branch):
            return """
                Bloom will not ask for a merge in '\(workspace)' because GitHub has no pull \
                request for its branch '\(branch)'. There is nothing to merge yet. Do not open \
                one to make this call succeed: opening a pull request is a decision of its own, \
                with the project's own instructions behind it, and Bloom has a button for it that \
                the owner presses. If you think there should be one, say so and let them.
                """

        case let .blocked(workspace, number, headline, reason):
            return """
                Bloom will not ask for a merge of #\(number) in '\(workspace)'. GitHub reports it \
                as '\(headline)'. \(reason) Retrying will not help while that is true, and none of \
                it is something this call can change. Do not mark the pull request ready, re-run \
                or skip a check, dismiss a review, or touch a branch protection rule to get round \
                it: each of those is a change to a repository other people share, and a refusal is \
                an answer rather than an obstacle.
                """

        case let .localWork(workspace, number, detail, needsCommit):
            let next = needsCommit
                ? "commit and push it first"
                : "push it first"
            return """
                Bloom will not ask for a merge of #\(number) in '\(workspace)' because that \
                worktree is holding work GitHub has not got: \(detail). A merge lands what GitHub \
                has, so none of that would be part of it. Bloom's own Merge button does allow \
                this, and only because it puts that same sentence in a dialogue the owner has to \
                accept before anything is sent. There is nobody on this connection to accept it, \
                so the answer here is no. Tell the owner what is outstanding and let them decide \
                whether to merge over it or \(next). Retrying will not help until one of those has \
                happened.
                """

        case let .wouldQueue(workspace, hold):
            return Self.queued(workspace: workspace, hold: hold)

        case .appRefused(let sentence):
            return "Bloom did not send the merge request. \(sentence)"
        }
    }

    /// Why nothing was sent into a workspace that is busy, and whether waiting is the answer.
    ///
    /// The three holds are `DeliveryHold`'s, asked rather than re-derived, so this tool and the
    /// bubble in the transcript agree about what a workspace is waiting for. What is not shared is
    /// the wording: `DeliveryHold.sentence` is written for somebody looking at a queue they can
    /// see, and every one of them promises the message will go later. This tool has no queue to
    /// promise anything about. It answers "a turn has begun" or it refuses, because a call that
    /// said a turn had begun over a message sitting in a queue would be the one lie this tool
    /// cannot afford.
    private static func queued(workspace: String, hold: DeliveryHold) -> String {
        switch hold {
        case .setup:
            return """
                Bloom will not ask for a merge in '\(workspace)' yet, because its setup script is \
                still running and nothing may be said to an agent in a worktree that is still \
                being built. A request sent now would sit in a queue rather than start a turn. \
                Wait, and ask again once workspace_list reports its setup_state as done.
                """
        case .question:
            return """
                Bloom will not ask for a merge in '\(workspace)' because its agent has stopped on \
                a permission question and is waiting for an answer. Writing into a turn that is \
                blocked on one is exactly what a backend refuses. Wait for the owner to answer it, \
                check with workspace_list that nothing is awaiting_permission, then ask again.
                """
        case .turn:
            return """
                Bloom will not ask for a merge in '\(workspace)' because its agent is in the \
                middle of a turn. Bloom will not queue a merge behind work in progress, because a \
                queued message is not a turn that has begun and this call would be answering with \
                something untrue. Wait for the turn to finish, check with workspace_list that \
                nothing is agent_running, then ask again.
                """
        case .none:
            // Unreachable: `.none` is what lets a send through. Said plainly rather than left to a
            // default, so widening `DeliveryHold` is a compile error here rather than a sentence
            // nobody wrote.
            return """
                Bloom will not ask for a merge in '\(workspace)' right now. Check with \
                workspace_list what it is doing and ask again.
                """
        }
    }
}
