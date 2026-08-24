import Foundation

/// Reading pull requests that no workspace has been made for yet, and checking one out.
///
/// A second file rather than more of `GitHub.swift` only because that file is about the pull
/// request belonging to a worktree that exists: it is keyed by branch, it caches by worktree, and
/// every call it makes runs with a worktree as its working directory. Everything here runs in the
/// project checkout instead, before there is a worktree to run in.
public extension GitHub {
    /// The fields the picker needs. `isCrossRepository` and `headRepositoryOwner` are what tell a
    /// fork's pull request from this repository's own, which decides the local branch name.
    private static var summaryFields: String {
        [
            "number", "title", "author", "headRefName", "baseRefName",
            "isDraft", "state", "isCrossRepository", "headRepositoryOwner",
        ].joined(separator: ",")
    }

    /// The open pull requests of the repository at `path`.
    ///
    /// Returns an empty list rather than throwing when the repository has no GitHub remote or gh
    /// cannot be used: the picker offers branches too, and a sheet that refuses to open because a
    /// project is not on GitHub would be worse than a sheet with one section missing. A real
    /// failure to talk to GitHub with everything in place does throw, because that is worth a
    /// sentence.
    static func openPullRequests(repoPath: String, limit: Int = 30) async throws -> [PullRequestListing] {
        guard await isAvailable() else { return [] }
        let result = try await Shell.run(
            "gh",
            ["pr", "list", "--state", "open", "--limit", String(limit), "--json", summaryFields],
            cwd: repoPath,
            timeout: .seconds(20)
        )
        guard result.ok else {
            if indicatesNotAGitHubRepository(stderr: result.stderr) { return [] }
            throw GitHubError("gh pr list failed: \(result.stderr.isEmpty ? result.stdout : result.stderr)")
        }
        return WorkspaceCheckoutPlan.offered(try decodePullRequestListings(from: Data(result.stdout.utf8)))
    }

    /// One pull request by number, whatever state it is in.
    ///
    /// `gh pr view` finds closed and merged ones as happily as open ones, which is why typing a
    /// number reaches pull requests the list deliberately does not offer.
    static func pullRequestSummary(number: Int, repoPath: String) async throws -> PullRequestListing {
        guard number > 0 else { throw GitHubError("\(number) is not a pull request number") }
        let result = try await Shell.run(
            "gh", ["pr", "view", String(number), "--json", summaryFields],
            cwd: repoPath,
            timeout: .seconds(20)
        )
        guard result.ok else {
            throw GitHubError(
                "Could not read pull request #\(number): "
                    + (result.stderr.isEmpty ? result.stdout : result.stderr)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return try decodePullRequestListing(from: Data(result.stdout.utf8))
    }

    /// `owner/name` for the repository at `path`, or nil when it is not on GitHub.
    static func repositorySlug(repoPath: String) async -> String? {
        guard let result = try? await Shell.run(
            "gh", ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
            cwd: repoPath,
            timeout: .seconds(20)
        ), result.ok else { return nil }
        let slug = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return slug.isEmpty ? nil : slug
    }

    /// Puts a pull request's head onto `localBranch` inside `worktree`.
    ///
    /// `gh pr checkout` rather than a hand written fetch, and the reason is the case Bloom's owner
    /// hits every day: a pull request from a fork. The head branch does not exist on `origin` at
    /// all, so a `git fetch origin <branch>` fails, and the fetch that does work is of
    /// `refs/pull/N/head`, which nothing about the pull request's branch name tells you. gh also
    /// writes the branch's remote and merge config, so a fix pushed from the review workspace
    /// goes back to the contributor's branch instead of trying to open a second pull request.
    ///
    /// It runs inside the freshly made worktree, which is why the project's own checkout is never
    /// touched: `gh pr checkout` is `git checkout` underneath, and run in the project it would
    /// have switched the branch out from under whatever the owner was doing there.
    static func checkoutPullRequest(
        number: Int, into worktree: String, localBranch: String
    ) async throws {
        guard number > 0 else { throw GitHubError("\(number) is not a pull request number") }
        guard Git.isValidBranchName(localBranch) else {
            throw GitHubError("'\(localBranch)' is not a valid branch name")
        }
        let result = try await Shell.run(
            "gh", ["pr", "checkout", String(number), "--branch", localBranch],
            cwd: worktree,
            // Longer than the twenty seconds every other gh call gets, because this one fetches
            // objects. A first review of a large repository's pull request is a real download.
            timeout: .seconds(120)
        )
        guard result.ok else {
            throw GitHubError(
                "Could not check out pull request #\(number): "
                    + (result.stderr.isEmpty ? result.stdout : result.stderr)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .suffix(400)
            )
        }
    }

    /// The seam the suite decodes against, so gh's shape can be held without a network.
    static func decodePullRequestListings(from data: Data) throws -> [PullRequestListing] {
        try payloads(from: data).map { $0.summary }
    }

    static func decodePullRequestListing(from data: Data) throws -> PullRequestListing {
        do {
            return try JSONDecoder().decode(PullRequestListPayload.self, from: data).summary
        } catch {
            throw GitHubError("Could not decode gh JSON: \(error)")
        }
    }

    static func indicatesNotAGitHubRepository(stderr: String) -> Bool {
        let text = stderr.lowercased()
        return text.contains("none of the git remotes configured for this repository")
            || text.contains("no git remotes found")
            || text.contains("could not determine base repository")
            || text.contains("not a git repository")
    }

    private static func payloads(from data: Data) throws -> [PullRequestListPayload] {
        do {
            return try JSONDecoder().decode([PullRequestListPayload].self, from: data)
        } catch {
            throw GitHubError("Could not decode gh JSON: \(error)")
        }
    }
}

/// gh nests the two logins one level down, so the payload is decoded rather than the model.
public struct PullRequestListPayload: Decodable, Sendable {
    struct Login: Decodable, Sendable {
        let login: String?
    }

    let number: Int?
    let title: String?
    let author: Login?
    let headRefName: String?
    let baseRefName: String?
    let isDraft: Bool?
    let state: String?
    let isCrossRepository: Bool?
    let headRepositoryOwner: Login?

    var summary: PullRequestListing {
        PullRequestListing(
            number: number ?? 0,
            title: title ?? "",
            author: author?.login ?? "",
            headRefName: headRefName ?? "",
            baseRefName: baseRefName ?? "",
            isDraft: isDraft ?? false,
            state: state ?? "OPEN",
            isCrossRepository: isCrossRepository ?? false,
            headRepositoryOwner: headRepositoryOwner?.login
        )
    }
}
