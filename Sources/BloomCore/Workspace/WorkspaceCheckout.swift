import Foundation

/// A pull request as the create sheet needs to talk about one: enough to list it, enough to name
/// the workspace after it, and enough to know which branch it will land on.
///
/// Separate from `PullRequest` on purpose. That type describes the pull request belonging to a
/// workspace that already exists, and every field on it is about status: mergeability, the review
/// decision, the check rollup. This one is about a pull request nothing has been checked out for
/// yet, so it carries the two things that type has no reason to know, the base ref and whether the
/// head lives in a fork, and none of the polling state.
public struct PullRequestListing: Sendable, Hashable, Identifiable, Codable {
    public let number: Int
    public let title: String
    public let author: String
    public let headRefName: String
    public let baseRefName: String
    public let isDraft: Bool
    /// `OPEN`, `CLOSED` or `MERGED`, as gh spells it.
    public let state: String
    /// Whether the head branch lives in a fork rather than in this repository.
    public let isCrossRepository: Bool
    /// The login owning the head repository, which is the fork's owner when there is one.
    public let headRepositoryOwner: String?

    public var id: Int { number }

    public var isOpen: Bool { state.uppercased() == "OPEN" }

    public init(
        number: Int,
        title: String,
        author: String = "",
        headRefName: String,
        baseRefName: String,
        isDraft: Bool = false,
        state: String = "OPEN",
        isCrossRepository: Bool = false,
        headRepositoryOwner: String? = nil
    ) {
        self.number = number
        self.title = title
        self.author = author
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.isDraft = isDraft
        self.state = state
        self.isCrossRepository = isCrossRepository
        self.headRepositoryOwner = headRepositoryOwner
    }
}

/// A branch that already exists somewhere, offered by the picker beside the pull requests.
public struct ExistingBranch: Sendable, Hashable, Identifiable, Codable {
    public let name: String
    /// Whether there is a local `refs/heads` copy. False means the branch is only on the remote,
    /// which needs a tracking branch made for it rather than a plain checkout.
    public let isLocal: Bool
    /// The live workspace already sitting on this branch, by name, or nil when it is free.
    ///
    /// Carried on the branch rather than worked out by the picker, because the picker used to be
    /// handed a list these branches had been taken out of: git refuses one branch in two
    /// worktrees, so an in-use branch was dropped, and the answer to "where is the branch I was
    /// working on yesterday" was silence. It is listed and marked instead, and selecting it goes
    /// to the workspace that has it. See `WorkspaceCheckoutPlan.workspaceHolding`, which is what
    /// turns this name back into the row to select.
    public let inUseBy: String?

    public var id: String { name }

    public init(name: String, isLocal: Bool, inUseBy: String? = nil) {
        self.name = name
        self.isLocal = isLocal
        self.inUseBy = inUseBy
    }
}

/// What a workspace is opened on, when it is not opened on a new branch.
///
/// The whole point of the feature: Bloom could only ever cut a branch, so it was where work is
/// delegated and never where work is reviewed. A checkout is the other direction, and the two
/// cases below are the same shape of thing, an existing head somebody else wrote, which is why
/// they travel as one value through `WorkspaceStartRequest`.
public enum WorkspaceCheckout: Sendable, Hashable {
    case pullRequest(PullRequestListing)
    case branch(ExistingBranch)
}

public extension WorkspaceCheckout {
    /// What the diff is measured against.
    ///
    /// For a pull request this is the pull request's own base ref rather than the project's
    /// default branch, and the difference is the whole reason a review workspace is worth having:
    /// a pull request into `v3` compared against `main` shows every commit `v3` carries as though
    /// the contributor had written it. `Git.baseline` then takes the merge base with that ref, so
    /// what the review tab draws is the three dot diff GitHub itself draws on the Files tab.
    ///
    /// A branch has nobody to ask, so it falls back to the project's default.
    func baseBranch(default defaultBranch: String) -> String {
        switch self {
        case .pullRequest(let request): request.baseRefName
        case .branch: defaultBranch
        }
    }

    /// What the sidebar row is called.
    ///
    /// The number goes first because that is how a review is referred to out loud, and because a
    /// list of workspaces named after pull request titles alone is a list of sentences. Nothing
    /// asks a model to rename these: the pull request already has a name somebody chose.
    var workspaceName: String {
        switch self {
        case .pullRequest(let request):
            let title = Git.title(from: request.title, maxLength: 44)
            return title.isEmpty ? "#\(request.number)" : "#\(request.number) \(title)"
        case .branch(let branch):
            return branch.name
        }
    }

    /// The local branch the worktree ends up on, before uniquing.
    ///
    /// The pull request's own head name, fork or no fork, and the reason is measured rather than
    /// aesthetic: gh finds the pull request belonging to a worktree by asking GitHub for the head
    /// `<owner>:<local branch>`, so a branch checked out under any other name has no pull request
    /// as far as gh is concerned. Renaming a fork's `perf/memoise` to `contributor-perf/memoise`,
    /// which is what this did first, left `gh pr view` in the worktree answering "no pull requests
    /// found for branch chengkangzai:chengkangzai-perf/memoise", and with it went the inspector's
    /// pull request panel, the checks view and everything else Bloom keys by branch. The whole
    /// point of a review workspace is that machinery, so the name is not ours to prettify.
    var preferredLocalBranch: String {
        switch self {
        case .pullRequest(let request): request.headRefName
        case .branch(let branch): branch.name
        }
    }

    /// What to call it when the preferred name is taken.
    ///
    /// Only forks have one, and it is the fork owner in front of the head name: two contributors
    /// both calling their branch `patch-1` is the ordinary case, and so is a branch of your own
    /// that means something else entirely. Losing gh's pull request lookup is the price, and it is
    /// the right way round: a second workspace on the same head is the rarer thing.
    var alternateLocalBranch: String? {
        guard case .pullRequest(let request) = self,
              request.isCrossRepository,
              let owner = request.headRepositoryOwner,
              !owner.isEmpty
        else { return nil }
        return "\(owner)-\(request.headRefName)"
    }
}

/// The decisions the create sheet used to have nowhere to make: which pull requests are worth
/// offering, what a typed number or URL means, what the branch is called once names collide, and
/// what to do about a branch that is already open somewhere.
public enum WorkspaceCheckoutPlan {
    /// Which pull requests the picker lists.
    ///
    /// Open ones, newest first, and drafts included: a draft is exactly the kind of pull request
    /// somebody pulls down to have a look at, and the sheet marks it rather than hiding it. A
    /// closed or merged one is not offered, because a list of every pull request a busy repository
    /// ever had is a list nobody can find today's work in. Typing its number still opens it, which
    /// is the deliberate difference between what is offered and what is allowed.
    public static func offered(_ requests: [PullRequestListing], limit: Int = 30) -> [PullRequestListing] {
        var seen = Set<Int>()
        return requests
            .filter(\.isOpen)
            .sorted { $0.number > $1.number }
            .filter { seen.insert($0.number).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// Which branches the picker lists, local and remote merged into one list.
    ///
    /// A branch that exists on both sides is one entry and it counts as local, because that is the
    /// checkout that will actually happen. `origin/HEAD` is dropped: it is a symbolic ref rather
    /// than a branch, and a worktree cut from it lands on a name nobody typed. The default branch
    /// is dropped too, because it is the one branch that is already checked out in the project
    /// itself and git will refuse it.
    ///
    /// A head with a pull request open on it is dropped as well, and that one is not tidiness.
    /// The two entries would open the same branch under different bases: the branch entry measures
    /// against the project's default, the pull request entry against the ref the pull request
    /// actually targets. Offering both is offering a coin flip over what the Changes tab means,
    /// and the pull request is the one that knows the answer. See `heads(of:)`.
    ///
    /// A branch a live workspace is already sitting on is NOT dropped. It used to be, because git
    /// refuses one branch in two worktrees and offering it would be offering a create that cannot
    /// succeed. That reasoning is right about the create and wrong about the list: the branch
    /// somebody is looking for is very often the one they were working on yesterday, and a picker
    /// that answers by not mentioning it reads as a branch that has gone. It is listed with the
    /// workspace holding it named on the row, and selecting it goes there instead of creating
    /// anything. See `ExistingBranch.inUseBy`.
    public static func offeredBranches(
        local: [String],
        remote: [String],
        defaultBranch: String,
        inUse: [String: String] = [:],
        pullRequestHeads: Set<String> = []
    ) -> [ExistingBranch] {
        var byName: [String: Bool] = [:]
        for name in local where !name.isEmpty { byName[name] = true }
        for reference in remote {
            let name = remoteBranchName(reference)
            guard let name, byName[name] == nil else { continue }
            byName[name] = false
        }
        byName[defaultBranch] = nil
        for name in pullRequestHeads { byName[name] = nil }
        return byName
            .map { ExistingBranch(name: $0.key, isLocal: $0.value, inUseBy: inUse[$0.key]) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The branches the offered pull requests are already speaking for.
    ///
    /// A fork's head is left out on purpose. It is not a branch of this repository at all, so a
    /// local or remote branch of the same name is somebody else's unrelated work wearing the same
    /// word, and hiding it would hide a branch the pull request cannot open in its place.
    public static func heads(of requests: [PullRequestListing]) -> Set<String> {
        Set(requests.filter { !$0.isCrossRepository }.map(\.headRefName))
    }

    /// `origin/feature/x` as `feature/x`, and nil for anything that is not a branch of the remote.
    static func remoteBranchName(_ reference: String, remote: String = "origin") -> String? {
        let prefix = remote + "/"
        guard reference.hasPrefix(prefix) else { return nil }
        let name = String(reference.dropFirst(prefix.count))
        guard !name.isEmpty, name != "HEAD" else { return nil }
        return name
    }

    /// A pull request number typed or pasted into the sheet.
    ///
    /// Everything anybody actually has on the clipboard resolves to the same thing: `1234`,
    /// `#1234`, the URL of the pull request, the URL of one of its files or of a comment on it.
    /// The URL carries the repository as well, which is not thrown away: pasting another
    /// repository's pull request into this project is a mistake worth naming rather than a number
    /// that quietly resolves to somebody else's work.
    public static func parseReference(_ text: String) -> PullRequestReference? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let host = url.host, host.contains("github") {
            let parts = url.path.split(separator: "/").map(String.init)
            guard let index = parts.firstIndex(where: { $0 == "pull" || $0 == "pulls" }),
                  index >= 2,
                  parts.count > index + 1,
                  let number = positiveNumber(parts[index + 1])
            else { return nil }
            return PullRequestReference(
                number: number, repository: "\(parts[index - 2])/\(parts[index - 1])"
            )
        }

        let bare = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard let number = positiveNumber(bare) else { return nil }
        return PullRequestReference(number: number, repository: nil)
    }

    private static func positiveNumber(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isNumber), let value = Int(text), value > 0 else {
            return nil
        }
        return value
    }

    /// The local branch this checkout lands on, given what the repository already has.
    ///
    /// A branch of that name already existing is the ordinary case rather than the error case:
    /// reviewing the same pull request twice in a fortnight is normal, and so is having fetched
    /// the branch by hand last week. Reusing it would mean silently opening a worktree on a stale
    /// head, or on whatever local commits were left on it, so a fresh name is taken instead and
    /// `gh` fetches the pull request into it. `Git.uniqueBranch` supplies the suffix, so the rule
    /// is the same one new workspaces have always used.
    public static func localBranch(
        for checkout: WorkspaceCheckout, taken: Set<String>
    ) -> String {
        if case .branch(let branch) = checkout {
            // An existing branch is the thing being asked for, not a collision with it, and that
            // holds whether or not there is a local copy of it yet. This used to ask `isLocal`,
            // which is a fact the picker measured seconds ago and about the wrong half: a branch
            // listed as remote that had since been fetched, or that the picker never saw locally
            // in the first place, was uniqued to `<name>-2` on the row while the worktree was put
            // on `<name>`, so the workspace's branch column named a branch that did not exist.
            // Whether a local ref is there is decided by git at the moment of the checkout. See
            // `WorkspaceManager.open`.
            return branch.name
        }
        let preferred = checkout.preferredLocalBranch
        guard taken.contains(preferred) else { return preferred }
        // **A branch of our own that the pull request is about is the branch to open.**
        //
        // `taken` is every branch in the project, so a pull request raised from this repository
        // always collides with its own head: the branch exists locally the moment it has been
        // fetched, which for your own work is always. That sent "Open, and carry on" on a pull
        // request to `<head>-2`, a branch with no pull request on it, so the strip offered Create
        // pull request for one that was already open and the push and merge buttons never
        // appeared. Reported from a real workspace made off a real pull request.
        //
        // The heading says carry on, and both kinds of row in it now mean the same thing: a
        // branch row already returns its name verbatim above. `gh pr checkout` brings an existing
        // branch up to the pull request head, so the stale-head worry the suffix was protecting
        // against is answered by the checkout rather than by the name.
        //
        // A fork keeps the suffix, which is what it was really written for: two contributors both
        // calling a branch `patch-1` is ordinary, and there the local branch of that name is
        // somebody else's unrelated work rather than the thing being asked for.
        if case .pullRequest(let request) = checkout, !request.isCrossRepository {
            return preferred
        }
        if let alternate = checkout.alternateLocalBranch, !taken.contains(alternate) {
            return alternate
        }
        return Git.uniqueBranch(checkout.alternateLocalBranch ?? preferred, taken: taken)
    }

    /// A workspace already sitting on this branch **of this project**, if there is one.
    ///
    /// Git refuses to check a branch out into two worktrees at once, so this is not a nicety: the
    /// answer decides between opening a second workspace and taking the one that is already there.
    /// Archived workspaces do not count, because their worktrees are gone.
    ///
    /// **The project is the half this was missing.** Git's refusal is per repository, and a branch
    /// name is not unique across them: `main`, `develop` and `staging` exist in nearly every
    /// project on a machine. Matching on the name alone meant the create sheet for project A
    /// labelled A's own `develop` "In use by ‹a workspace in project B›", and picking that row
    /// dismissed the sheet and selected B's workspace. Somebody asked for a workspace in A and
    /// landed in an unrelated project, with nothing on screen saying why.
    public static func workspaceHolding(
        branch: String, in repoID: RepoID, among workspaces: [Workspace]
    ) -> Workspace? {
        workspaces.first { $0.state == .active && $0.repoID == repoID && $0.branch == branch }
    }

    /// What the sheet says about a pull request before it is opened, or nil when there is nothing
    /// worth saying.
    ///
    /// Closed and merged pull requests are checked out rather than refused, because reading the
    /// code of something that landed last week is a real reason to open one. The sentence exists
    /// so that an empty diff and a dead branch are expected rather than a bug being hunted.
    public static func warning(for checkout: WorkspaceCheckout) -> String? {
        guard case .pullRequest(let request) = checkout else { return nil }
        switch request.state.uppercased() {
        case "MERGED": return "This pull request is already merged."
        case "CLOSED": return "This pull request was closed without merging."
        default: return nil
        }
    }
}

/// A pull request named by number, and the repository it was named in when the text said so.
public struct PullRequestReference: Sendable, Hashable {
    public let number: Int
    /// `owner/name` when the reference came from a URL, nil when a bare number was typed.
    public let repository: String?

    public init(number: Int, repository: String? = nil) {
        self.number = number
        self.repository = repository
    }
}

/// Turning what somebody typed into the sheet into something checkoutable.
///
/// The three answers are deliberately three: a pull request to open, a sentence explaining why
/// there is not one, and nothing at all for an empty box. A view that had to tell those apart from
/// an optional and a thrown error would be making the decision itself, out of reach of the suite.
public enum WorkspaceCheckoutResolution: Sendable, Equatable {
    case checkout(WorkspaceCheckout)
    case failure(String)
}

public enum WorkspaceCheckoutResolver {
    /// What is wrong with a reference before gh is asked anything, or nil when it is worth asking.
    ///
    /// The repository check is the one worth having: pasting a pull request URL from another
    /// project into this project's sheet resolves, under gh, to whatever this repository happens
    /// to have as number 42. Being told the numbers belong to different repositories is a fixable
    /// mistake; silently reviewing the wrong pull request is not.
    public static func problem(
        with text: String, in repository: String?
    ) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Type a pull request number or paste its URL."
        }
        guard let reference = WorkspaceCheckoutPlan.parseReference(text) else {
            return "'\(text.trimmingCharacters(in: .whitespacesAndNewlines))' is not a pull request number or URL."
        }
        if let repository, let named = reference.repository,
           named.lowercased() != repository.lowercased() {
            return "That pull request belongs to \(named), and this project is \(repository)."
        }
        return nil
    }

    /// The whole of it, including the gh call. Lives here rather than in the sheet so the sheet is
    /// left drawing a text field and reading an answer.
    public static func resolve(_ text: String, repoPath: String) async -> WorkspaceCheckoutResolution {
        let slug = await GitHub.repositorySlug(repoPath: repoPath)
        if let problem = problem(with: text, in: slug) { return .failure(problem) }
        guard let reference = WorkspaceCheckoutPlan.parseReference(text) else {
            return .failure("That is not a pull request number or URL.")
        }
        do {
            let summary = try await GitHub.pullRequestSummary(
                number: reference.number, repoPath: repoPath
            )
            return .checkout(.pullRequest(summary))
        } catch {
            return .failure(error.readableMessage)
        }
    }
}
