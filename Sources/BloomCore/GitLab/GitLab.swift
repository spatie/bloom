import Foundation

/// The glab boundary, read as `PullRequest` and `CheckRun`.
///
/// Reads use `glab api` on the versioned REST API with the host and project named, rather than
/// glab's own JSON and remote guessing. `GitLabReads` shares what can be shared.
public enum GitLab: ForgeClient {
    @TaskLocal static var commandOverride: (@Sendable ([String], String?) async throws -> ShellResult)?

    private static let readTimeout = Duration.seconds(20)
    /// Checking out fetches objects, so it gets what `gh pr checkout` gets.
    private static let checkoutTimeout = Duration.seconds(120)
    /// One merge request's head, over the network.
    private static let fetchTimeout = Duration.seconds(60)
    private static let logTimeout = Duration.seconds(90)
    /// What `gh pr merge` and `gh pr create` get.
    private static let mergeTimeout = Duration.seconds(60)
    /// `glab mr rebase` polls until GitLab is done; this caps a rebase that never is.
    private static let rebaseTimeout = Duration.seconds(120)
    private static let candidateLimit = 20
    private static let jobLimit = 100
    private static let commitLimit = 100
    private static let listLimit = 30

    public static func access(in directory: String) async -> GitHubAccess {
        guard isInstalled else { return .notInstalled }
        guard let project = await project(in: directory) else { return .signedOut }
        return await access(host: project.host)
    }

    /// glab's state on one host, for a sign in that names it.
    public static func access(host: String) async -> GitHubAccess {
        guard isInstalled else { return .notInstalled }
        guard let result = try? await run(["auth", "status", "--hostname", host], cwd: nil) else { return .signedOut }
        return result.ok ? .ready : .signedOut
    }

    public static func readPullRequest(for workspace: Workspace, maxAge: Duration) async -> PullRequestRead {
        guard commandOverride != nil || Shell.which("glab") != nil else {
            return .unavailable(GitHubReadFailure(
                reason: .unavailable, message: "Install the GitLab CLI to refresh merge requests."
            ))
        }
        do { return .current(try await pullRequest(for: workspace, maxAge: maxAge)) } catch {
            let failure = GitHubReadFailure.classify(error)
            let refused = failure.reason == .authentication || ((error as? ShellError)?.stderr.contains("401") ?? false)
            return .unavailable(refused ? GitHubReadFailure(
                reason: .authentication, message: "Connect GitLab again to refresh merge requests."
            ) : failure)
        }
    }

    public static func pullRequest(for workspace: Workspace, maxAge: Duration) async throws -> PullRequest? {
        try await GitLabReads.shared.snapshot(for: readKey(workspace), maxAge: maxAge) {
            try await snapshot(for: workspace)
        }?.pullRequest
    }

    public static func pullRequest(forBranch branch: String, worktree: String) async throws -> PullRequest? {
        guard let project = await project(in: worktree) else { return nil }
        let candidates = try await mergeRequests(withSource: branch, in: project, worktree: worktree)
            .filter { $0.sourceProjectId == $0.targetProjectId }
        let chosen = candidates.first { $0.state == "opened" } ?? candidates.first
        guard let iid = chosen?.iid else { return nil }
        return try await snapshot(number: iid, in: project, worktree: worktree).pullRequest
    }

    public static func checks(for workspace: Workspace) async throws -> [CheckRun]? {
        let found = try await GitLabReads.shared.snapshot(for: readKey(workspace), maxAge: .zero) {
            try await snapshot(for: workspace)
        }
        // Nil when the jobs could not be read, as on GitHub, so the tab says so.
        guard let found else { return [] }
        return found.pullRequest.checks == .unavailable ? nil : found.runs
    }

    public static func markReadyForReview(_ pullRequest: PullRequest, worktree: String) async throws {
        guard pullRequest.isOpen, pullRequest.isDraft else {
            throw GitHubError("This merge request is no longer an open draft.")
        }
        guard let project = await project(in: worktree) else { throw notAProject }
        try await check(["mr", "update", String(pullRequest.number), "--ready", "-R", project.webURL], cwd: worktree)
    }

    public static func checkRunLog(_ target: CheckFailureHandoff.LogTarget, worktree: String) async throws -> String {
        guard let jobID = target.jobID, let projectPath = target.project else {
            throw GitHubError("Bloom could not tell which GitLab job this is.")
        }
        guard let project = await project(in: worktree) else { throw notAProject }
        let jobProject = GitLabProject(remote: "https://\(project.host)/\(projectPath)") ?? project
        let result = try await run(
            api(project.host, "projects/\(jobProject.apiID)/jobs/\(jobID)/trace"), cwd: worktree, timeout: logTimeout
        )
        guard result.ok, !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitHubError(result.stderr.isEmpty ? "glab returned no log for this job" : result.stderr)
        }
        return result.stdout
    }

    public static func openPullRequests(repoPath: String) async throws -> [PullRequestListing] {
        guard let project = await project(in: repoPath) else { return [] }
        let result = try await check(
            api(project.host, "projects/\(project.apiID)/merge_requests?state=opened&per_page=\(listLimit)"),
            cwd: repoPath
        )
        let listings = try GitLabDecoding.mergeRequests(from: Data(result.stdout.utf8)).map(GitLabDecoding.listing)
        return WorkspaceCheckoutPlan.offered(listings)
    }

    public static func pullRequestSummary(number: Int, repoPath: String) async throws -> PullRequestListing {
        guard number > 0 else { throw GitHubError("\(number) is not a merge request number") }
        guard let project = await project(in: repoPath) else { throw notAProject }
        let result = try await check(
            api(project.host, "projects/\(project.apiID)/merge_requests/\(number)"), cwd: repoPath
        )
        return GitLabDecoding.listing(try GitLabDecoding.mergeRequest(from: Data(result.stdout.utf8)))
    }

    public static func repositorySlug(repoPath: String) async -> String? {
        await project(in: repoPath)?.path
    }

    public static func checkoutPullRequest(number: Int, into worktree: String, localBranch: String) async throws {
        guard number > 0 else { throw GitHubError("\(number) is not a merge request number") }
        guard Git.isValidBranchName(localBranch) else {
            throw GitHubError("'\(localBranch)' is not a valid branch name")
        }
        guard let project = await project(in: worktree) else { throw notAProject }
        try await check(
            ["mr", "checkout", String(number), "--branch", localBranch, "-R", project.webURL],
            cwd: worktree, timeout: checkoutTimeout
        )
    }

    // MARK: Creating and merging directly

    /// The workspace's title, and the pushed commits for the description, as `gh pr create --fill`
    /// does. Not glab's own `--fill`, which pushes again to a remote of its choosing.
    public static func createPullRequestFromCommits(
        worktree: String, base: String, title: String
    ) async throws -> PullRequest {
        guard Git.isValidBranchName(base) else {
            throw GitHubError("refusing to open a merge request against '\(base)': not a valid branch name")
        }
        guard let project = await project(in: worktree) else { throw notAProject }
        let context = try await Git.repositoryContext(in: worktree, baseBranch: base)
        let log = try await Git.check(
            ["log", "--reverse", "--format=%s%x1f%b%x1e", "\(context.baseTrackingRef ?? base)..HEAD", "--"],
            in: worktree
        )
        var arguments = [
            "mr", "create", "--source-branch", context.publishBranch, "--target-branch", base,
            "--title", title, "--description", description(fromCommits: commits(fromLog: log.stdout)),
            "--yes", "-R", project.webURL,
        ]
        if let fork = GitLabProject(remote: context.publishRemoteURL), fork != project {
            arguments += ["--head", fork.webURL]
        }
        let created = try await check(arguments, cwd: worktree, timeout: mergeTimeout)
        guard let number = mergeRequestNumber(in: created.stdout) else {
            throw GitHubError("glab did not say which merge request it opened.")
        }
        return try await snapshot(number: number, in: project, worktree: worktree).pullRequest
    }

    /// Merges exactly what the owner confirmed. `--sha` holds GitLab to the head that was shown,
    /// and `--auto-merge=false` stops glab from merging later, once the pipeline passes.
    public static func mergePullRequest(
        _ expected: PullRequest, into base: String, method: GitHub.MergeMethod,
        squashMessage: SquashCommitMessage? = nil, worktree: String
    ) async throws -> DirectMergeOutcome {
        let (head, expectedBase) = try await DirectMergeCheck.confirmed(expected, base: base, worktree: worktree)
        guard let remote = await remote(in: worktree) else { throw notAProject }
        let project = remote.project
        let number = expected.number
        let current = try await snapshot(number: number, in: project, worktree: worktree).pullRequest
        try DirectMergeCheck.verify(current, against: expected, head: head, base: expectedBase)

        var mergeHead = head
        if method == .rebase {
            mergeHead = try await rebase(number, confirmedHead: head, through: remote, worktree: worktree)
        }
        var arguments = ["mr", "merge", String(number), "--yes", "--auto-merge=false", "--sha", mergeHead]
        if method == .squash {
            arguments.append("--squash")
            if let squashMessage { arguments += ["--squash-message", squashMessage.commitMessage] }
        }
        arguments += ["-R", project.webURL]
        let result = try await run(arguments, cwd: worktree, timeout: mergeTimeout)
        let after = try? await snapshot(number: number, in: project, worktree: worktree).pullRequest
        guard result.ok else {
            if after?.isMerged == true { return .merged }
            let refusal = result.stderr.isEmpty ? result.stdout : result.stderr
            guard method != .rebase else {
                throw GitHubError("GitLab rebased \(Forge.gitLab.reference(number)) but did not merge it: \(refusal)")
            }
            throw ShellError(command: "glab " + arguments.joined(separator: " "), status: result.status, stderr: refusal)
        }
        guard let after else { return .acceptedUnverified }
        return after.isMerged ? .merged : .acceptedButOpen
    }

    /// glab's `--rebase` rebases, then GitLab refuses the `--sha` it was given. So the rebase runs
    /// first, and its new head is merged only if it replayed the confirmed changes and nothing else.
    private static func rebase(
        _ number: Int, confirmedHead: String, through remote: GitLabRemote, worktree: String
    ) async throws -> String {
        let project = remote.project
        let confirmed = try await commits(of: number, in: project, worktree: worktree)
        guard confirmed.contains(where: { $0.sha == confirmedHead }) else {
            throw GitHubError("The merge request changed since it was shown. Refresh it before merging.")
        }
        try await check(["mr", "rebase", String(number), "-R", project.webURL], cwd: worktree, timeout: rebaseTimeout)
        let rebased = try await snapshot(number: number, in: project, worktree: worktree).pullRequest
        // Already on its target, GitLab leaves the head as it was: the confirmed commits themselves.
        if rebased.headRevision == confirmedHead { return confirmedHead }
        let replayed = try await commits(of: number, in: project, worktree: worktree)
        guard let head = rebased.headRevision, DirectMergeCheck.isCommitID(head),
              replayed.contains(where: { $0.sha == head }), replayed.count == confirmed.count,
              // One page of commits: a longer merge request is refused rather than paged through.
              replayed.count < commitLimit,
              try await fetchedHead(of: number, from: remote, worktree: worktree) == head,
              try await holdsConfirmedChanges(head, commits: replayed.count, confirmedHead: confirmedHead, worktree: worktree)
        else {
            throw GitHubError("GitLab rebased \(Forge.gitLab.reference(number)), but its commits are not the ones confirmed. Nothing was merged.")
        }
        return head
    }

    /// The merge request's head as git fetches it, so its commits can be compared with this checkout's.
    private static func fetchedHead(of number: Int, from remote: GitLabRemote, worktree: String) async throws -> String? {
        let fetch = ["fetch", "--no-tags", "--quiet", "--", remote.name, "refs/merge-requests/\(number)/head"]
        guard try await Git.run(fetch, in: worktree, timeout: fetchTimeout).ok else {
            throw GitHubError("GitLab rebased \(Forge.gitLab.reference(number)), but Bloom could not fetch it from \(remote.name) to check its commits. Nothing was merged.")
        }
        return await Git.revision(of: "FETCH_HEAD", in: worktree)
    }

    /// Whether the rebased head holds exactly what merging the confirmed head onto its new base
    /// gives, so a push with the same titles and other contents is never merged. Trees rather than
    /// patch ids, which count context lines and so refuse a target that moved a line nearby.
    private static func holdsConfirmedChanges(
        _ head: String, commits count: Int, confirmedHead: String, worktree: String
    ) async throws -> Bool {
        let merged = try await Git.run(["merge-tree", "--write-tree", "\(head)~\(count)", confirmedHead], in: worktree)
        let rebased = try await Git.run(["rev-parse", "--verify", "\(head)^{tree}"], in: worktree)
        guard merged.ok, rebased.ok, let tree = merged.lines.first else { return false }
        return tree == rebased.trimmed
    }

    private static func commits(
        of number: Int, in project: GitLabProject, worktree: String
    ) async throws -> [GitLabDecoding.CommitPayload] {
        let result = try await check(
            api(project.host, "projects/\(project.apiID)/merge_requests/\(number)/commits?per_page=\(commitLimit)"),
            cwd: worktree
        )
        return try GitLabDecoding.commits(from: Data(result.stdout.utf8))
    }

    /// One commit's own body, or the subjects of several, oldest first: `gh pr create --fill`.
    static func description(fromCommits commits: [(subject: String, body: String)]) -> String {
        if commits.count == 1 { return commits[0].body.trimmingCharacters(in: .whitespacesAndNewlines) }
        return commits.map { "- \($0.subject)" }.joined(separator: "\n")
    }

    /// `git log --format=%s%x1f%b%x1e` read back into subjects and bodies.
    static func commits(fromLog output: String) -> [(subject: String, body: String)] {
        output.split(separator: "\u{1e}").compactMap { record in
            let fields = record.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
            let subject = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subject.isEmpty else { return nil }
            return (subject, fields.count > 1 ? String(fields[1]) : "")
        }
    }

    /// The number at the end of the merge request URL glab prints once it has opened one.
    static func mergeRequestNumber(in output: String) -> Int? {
        guard let range = output.range(of: #"/-/merge_requests/(\d+)"#, options: [.regularExpression, .backwards])
        else { return nil }
        return Int(output[range].split(separator: "/").last ?? "")
    }

    // MARK: Reading one merge request

    /// A worktree whose branch changed is asking a different question.
    private static func readKey(_ workspace: Workspace) -> String {
        "\(workspace.path)\n\(workspace.branch)"
    }

    struct Snapshot: Sendable {
        let pullRequest: PullRequest
        let runs: [CheckRun]
    }

    /// The newest merge request from the workspace's head that had not ended before it existed,
    /// else the one on the row. GitLab filters on the recorded source branch, so the first survives
    /// the branch being deleted; the row's number is the only way to a fork's merge request, whose
    /// local branch glab names after nothing GitLab knows, and to a branch renamed since.
    static func snapshot(for workspace: Workspace) async throws -> Snapshot? {
        guard let project = await project(in: workspace.path) else { return nil }
        let head = await GitHub.headBranch(of: workspace)
        let candidates = try await mergeRequests(withSource: head, in: project, worktree: workspace.path)
        // A fork's merge request with the same branch name is somebody else's.
        let matches = candidates.compactMap { candidate -> PullRequestHeadMatch? in
            guard let iid = candidate.iid, candidate.sourceProjectId == candidate.targetProjectId else { return nil }
            let ended = GitLabDecoding.pullRequest(candidate, runs: []).closedAt
            return PullRequestHeadMatch(number: iid, closedAt: ended)
        }
        let chosen = PullRequestOwnership.choose(from: matches, startedAt: workspace.createdAt, checkedOutAs: nil)
        guard let number = chosen ?? workspace.pullRequestNumber else { return nil }
        return try await snapshot(number: number, in: project, worktree: workspace.path)
    }

    private static func snapshot(number: Int, in project: GitLabProject, worktree: String) async throws -> Snapshot {
        let detail = try await check(
            api(project.host, "projects/\(project.apiID)/merge_requests/\(number)"), cwd: worktree
        )
        let payload = try GitLabDecoding.mergeRequest(from: Data(detail.stdout.utf8))
        guard let pipeline = payload.headPipeline else {
            return Snapshot(pullRequest: GitLabDecoding.pullRequest(payload, runs: []), runs: [])
        }
        let pipelineProject = pipeline.projectId.map(String.init) ?? project.apiID
        let pipelineKey = "\(project.host)/\(pipelineProject)/\(pipeline.id)"
        if let runs = await GitLabReads.shared.jobs(of: pipelineKey, status: pipeline.status) {
            return Snapshot(pullRequest: GitLabDecoding.pullRequest(payload, runs: runs), runs: runs)
        }
        // An unreadable pipeline (a private fork) means unknown checks, not no merge request.
        guard let jobs = try? await check(
            api(project.host, "projects/\(pipelineProject)/pipelines/\(pipeline.id)/jobs?per_page=\(jobLimit)"),
            cwd: worktree
        ), let runs = try? GitLabDecoding.jobs(from: Data(jobs.stdout.utf8)) else {
            return Snapshot(pullRequest: GitLabDecoding.pullRequest(payload, runs: nil), runs: [])
        }
        await GitLabReads.shared.remember(runs, of: pipelineKey, status: pipeline.status)
        return Snapshot(pullRequest: GitLabDecoding.pullRequest(payload, runs: runs), runs: runs)
    }

    private static func mergeRequests(
        withSource branch: String, in project: GitLabProject, worktree: String
    ) async throws -> [GitLabDecoding.MergeRequestPayload] {
        guard Git.isValidBranchName(branch) else { return [] }
        let query = "source_branch=\(queryValue(branch))&state=all&order_by=created_at&sort=desc"
            + "&per_page=\(candidateLimit)"
        let result = try await check(
            api(project.host, "projects/\(project.apiID)/merge_requests?\(query)"), cwd: worktree
        )
        return try GitLabDecoding.mergeRequests(from: Data(result.stdout.utf8))
    }

    // MARK: Running glab

    /// Whether glab is on this Mac: a walk of the PATH, no process.
    public static var isInstalled: Bool {
        commandOverride != nil || Shell.which("glab") != nil
    }

    /// The GitLab host this repository's base remote is on, for signing in to it.
    public static func host(in directory: String) async -> String? {
        await project(in: directory)?.host
    }

    static func project(in directory: String) async -> GitLabProject? {
        await remote(in: directory)?.project
    }

    static func remote(in directory: String) async -> GitLabRemote? {
        guard let config = Git.repositoryPaths(in: directory).map({ ($0.commonDirectory as NSString).appendingPathComponent("config") })
        else { return nil }
        let written = (try? FileManager.default.attributesOfItem(atPath: config))?[.modificationDate] as? Date
        if let known = await GitLabReads.shared.remote(in: directory, configWritten: written) { return known }
        let context = try? await Git.repositoryContext(in: directory)
        let configuration = (try? await Git.repositoryConfiguration(in: directory)) ?? [:]
        let remotes = configuration.reduce(into: [String: String]()) { remotes, entry in
            guard entry.key.hasPrefix("remote."), entry.key.hasSuffix(".url") else { return }
            remotes[String(entry.key.dropFirst("remote.".count).dropLast(".url".count))] = entry.value
        }
        let remote = GitLabRemote.choose(
            base: context?.baseRemote, remotes: remotes, signedInHosts: Set(GitLabIdentity.usernames.keys)
        )
        await GitLabReads.shared.store(remote, in: directory, configWritten: written)
        return remote
    }

    /// Points the branch's pushes at the GitLab remote when they would go anywhere else, such as a
    /// GitHub `origin`: GitLab can only open a merge request from a branch it has.
    static func routePushes(of branch: String, in worktree: String) async throws {
        guard Git.isValidBranchName(branch) else { throw GitHubError("'\(branch)' is not a valid branch name") }
        guard let remote = await remote(in: worktree) else { throw notAProject }
        let context = try await Git.repositoryContext(in: worktree, branch: branch)
        guard GitLabProject(remote: context.publishRemoteURL)?.host != remote.project.host else { return }
        try await Git.check(["config", "branch.\(branch).pushRemote", remote.name], in: worktree)
    }

    private static let notAProject = GitHubError("This repository has no GitLab remote Bloom can read.")

    private static func api(_ host: String, _ endpoint: String) -> [String] {
        ["api", "--hostname", host, endpoint]
    }

    private static func queryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }

    @discardableResult
    private static func check(
        _ arguments: [String], cwd: String?, timeout: Duration = readTimeout
    ) async throws -> ShellResult {
        let result = try await run(arguments, cwd: cwd, timeout: timeout)
        guard result.ok else {
            throw ShellError(
                command: "glab " + arguments.joined(separator: " "),
                status: result.status,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return result
    }

    private static func run(
        _ arguments: [String], cwd: String?, timeout: Duration = readTimeout
    ) async throws -> ShellResult {
        if let commandOverride { return try await commandOverride(arguments, cwd) }
        return try await Shell.run("glab", arguments, cwd: cwd, timeout: timeout)
    }
}
