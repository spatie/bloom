import Foundation

/// Repository ownership and creation, before a workspace has been cut.
private struct LoginPayload: Decodable {
    let login: String
}

public extension GitHub {
    /// The accounts this token may create a repository under: the signed in user first, then every
    /// organisation they belong to.
    ///
    /// Membership is not the same as permission. An organisation can forbid members from creating
    /// repositories, and there is no cheap way to ask which ones do, so the list is what the user
    /// belongs to and a refusal comes back from the create step with GitHub's own wording. Being
    /// told "you are not allowed to create repositories in this org" is a better outcome than
    /// hiding the org and leaving the user wondering where it went.
    static func owners() async throws -> [GitHubOwner] {
        let me = try await api(["user"], timeout: .seconds(20))
        let user = try JSONDecoder().decode(LoginPayload.self, from: Data(me.utf8))

        var owners = [GitHubOwner(login: user.login, kind: .user)]
        // Organisations are a nicety. A token without `read:org` returns nothing useful here, and
        // that must not stop somebody creating a repository under their own account.
        if let orgs = try? await api(["user/orgs", "--paginate"], timeout: .seconds(20)),
           let decoded = try? JSONDecoder().decode([LoginPayload].self, from: Data(orgs.utf8)) {
            owners += decoded.map { GitHubOwner(login: $0.login, kind: .organization) }
        }
        return owners
    }

    /// Whether `owner/name` already exists.
    ///
    /// Three answers, not two. A check that could not reach GitHub returns `unknown` carrying the
    /// reason, because reporting a name as free on the strength of a failed request is how a user
    /// ends up pressing a button that fails after their folder has already been committed.
    ///
    /// One blind spot worth naming: a repository that exists but this token cannot see answers 404
    /// like one that does not exist. That reads as available here and is refused by GitHub at
    /// creation time, with GitHub's own sentence.
    static func repositoryAvailability(owner: String, name: String) async -> NameAvailability {
        guard GitHubRepositoryName.isValid(name), isPlausibleLogin(owner) else {
            return .unknown("Bloom did not check that name.")
        }
        guard let result = try? await run(
            "gh", ["api", "--silent", "repos/\(owner)/\(name)"], timeout: .seconds(15)
        ) else {
            return .unknown("Bloom could not reach GitHub to check that name.")
        }
        if result.ok { return .taken }

        let output = result.stderr + result.stdout
        if output.contains("HTTP 404") || output.localizedCaseInsensitiveContains("not found") {
            return .available
        }
        return .unknown("Bloom could not check that name with GitHub.")
    }

    /// Creates an empty repository and returns the URL to add as `origin`.
    ///
    /// Nothing is pushed here. `gh repo create --source --push` would do the whole thing in one
    /// call, and it is deliberately not used: the create and the push fail for different reasons
    /// and leave the folder in different states, and a single exit code cannot tell the user which
    /// of the two happened.
    ///
    /// `isPrivate` has no default. Publishing somebody's folder is not a thing to get by omission.
    static func createRepository(
        owner: String, name: String, isPrivate: Bool
    ) async throws -> String {
        if let problem = GitHubRepositoryName.problem(with: name) {
            throw GitHubError(problem.sentence)
        }
        guard isPlausibleLogin(owner) else {
            throw GitHubError("'\(owner)' is not a GitHub account name.")
        }

        let arguments = [
            "repo", "create", "\(owner)/\(name)", isPrivate ? "--private" : "--public",
        ]
        let result = try await run("gh", arguments, timeout: .seconds(60))
        guard result.ok else {
            throw ShellError(
                command: "gh " + arguments.joined(separator: " "),
                status: result.status,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return await remoteURL(owner: owner, name: name)
    }

    /// The address to give `origin`, in whichever protocol the user has told gh they prefer.
    /// Somebody who clones over SSH everywhere should not get one HTTPS remote from Bloom.
    static func remoteURL(owner: String, name: String) async -> String {
        let configured = try? await run(
            "gh", ["config", "get", "git_protocol"], timeout: .seconds(10)
        )
        let usesSSH = (configured?.ok ?? false) && configured?.trimmed == "ssh"
        return usesSSH
            ? "git@github.com:\(owner)/\(name).git"
            : "https://github.com/\(owner)/\(name).git"
    }

    /// The page to open once a repository exists.
    static func repositoryPage(owner: String, name: String) -> String {
        "https://github.com/\(owner)/\(name)"
    }

    /// GitHub logins are alphanumerics and single hyphens. Checked because the login reaches gh as
    /// part of a path and as part of a URL.
    static func isPlausibleLogin(_ login: String) -> Bool {
        guard !login.isEmpty, login.count <= 39, !login.hasPrefix("-"), !login.hasSuffix("-") else {
            return false
        }
        return login.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func api(_ path: [String], timeout: Duration) async throws -> String {
        let arguments = ["api"] + path
        let result = try await run("gh", arguments, timeout: timeout)
        guard result.ok else {
            throw ShellError(
                command: "gh " + arguments.joined(separator: " "),
                status: result.status,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return result.stdout
    }
}
