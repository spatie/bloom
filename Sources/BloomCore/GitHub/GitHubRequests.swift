import Foundation

/// Only identical reads share a task. A cancelled inspector cannot cancel a request also being
/// consumed by the sidebar, and an explicit mutation is never coalesced or automatically retried.
actor GitHubRequests {
    struct Key: Hashable, Sendable {
        let host: String
        let directory: String?
        let arguments: [String]
    }
    private struct Flight {
        let id: UUID
        let task: Task<ShellResult, Error>
    }
    private var flights: [Key: Flight] = [:]
    private let limits = GitHubRateLimits()
    private(set) var activeSubscribers = 0

    func run(
        key: Key, interactive: Bool,
        execute: @escaping @Sendable () async throws -> ShellResult
    ) async throws -> ShellResult {
        try Task.checkCancellation()
        if !interactive, let flight = flights[key] {
            return try await wait(for: flight.task)
        }
        let lease = try await limits.check(host: key.host, interactive: interactive)
        try Task.checkCancellation()
        // Checking another actor suspends this one. A sibling may have installed the same
        // request while the rate-limit check was in flight.
        if !interactive, let flight = flights[key] {
            return try await wait(for: flight.task)
        }
        let id = UUID()
        let task = Task { [limits] in
            let result = try await execute()
            if !result.ok && GitHubReadFailure.isRateLimit(result.stderr + result.stdout) {
                let retryAt = await limits.limited(
                    host: key.host, lease: lease,
                    retryAt: GitHubReadFailure.retryDate(from: result.stderr, now: Date())
                )
                throw GitHubReadFailure(
                    reason: .rateLimited, message: "GitHub's rate limit was reached. Refresh will resume automatically.",
                    retryAt: retryAt
                )
            }
            if result.ok { await limits.succeeded(host: key.host, lease: lease) }
            return result
        }
        if !interactive {
            flights[key] = Flight(id: id, task: task)
            Task { [weak self] in
                _ = try? await task.value
                await self?.completed(key: key, id: id)
            }
        }
        return try await wait(for: task)
    }

    private func wait(for task: Task<ShellResult, Error>) async throws -> ShellResult {
        activeSubscribers += 1
        defer { activeSubscribers -= 1 }
        return try await GitHubRequestWaiter.value(of: task)
    }

    private func completed(key: Key, id: UUID) {
        if flights[key]?.id == id { flights[key] = nil }
    }
}

extension GitHub {
    private static let requests = GitHubRequests()
    @TaskLocal static var commandOverride: (@Sendable ([String], String?) async throws -> ShellResult)?

    static func run(
        _ executable: String, _ arguments: [String] = [], cwd: String? = nil,
        timeout: Duration = .seconds(20), repositoryContext: GitRepositoryContext? = nil
    ) async throws -> ShellResult {
        guard executable == "gh" else {
            return try await Shell.run(executable, arguments, cwd: cwd, timeout: timeout)
        }
        let context: GitRepositoryContext?
        if let repositoryContext { context = repositoryContext } else {
            context = await readContext(arguments: arguments, cwd: cwd)
        }
        let action = arguments.dropFirst().first ?? ""
        let interactive = ["create", "edit", "merge", "checkout", "delete"].contains(action)
        let resolved = repositoryArguments(arguments, context: context)
        let host = requestHost(arguments: resolved, context: context)
        let command = commandOverride
        return try await requests.run(
            key: .init(host: host, directory: cwd, arguments: resolved), interactive: interactive
        ) {
            if let command { return try await command(resolved, cwd) }
            return try await Shell.run(executable, resolved, cwd: cwd, timeout: timeout)
        }
    }

    static func readContext(arguments: [String], cwd: String?) async -> GitRepositoryContext? {
        guard let cwd else { return nil }
        let base = arguments.firstIndex(of: "--base").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        let branch: String? = if arguments.count > 2, arguments[0] == "pr", arguments[1] == "view",
                                Git.isValidBranchName(arguments[2]), Int(arguments[2]) == nil {
            arguments[2]
        } else { nil }
        return try? await Git.repositoryContext(in: cwd, baseBranch: base, branch: branch)
    }

    static func requestHost(arguments: [String], context: GitRepositoryContext?) -> String {
        if let repository = repositoryOption(in: arguments) {
            let pieces = repository.split(separator: "/")
            if pieces.count == 3 { return String(pieces[0]).lowercased() }
        }
        if let url = arguments.compactMap({ URL(string: $0) }).first(where: { $0.scheme == "https" || $0.scheme == "http" }),
           let host = url.host { return host.lowercased() }
        return repositoryHost(context?.baseRemoteURL) ?? ProcessInfo.processInfo.environment["GH_HOST"] ?? "github.com"
    }

    private static func repositoryOption(in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == "--repo" || argument == "-R", arguments.indices.contains(index + 1) {
                return arguments[index + 1]
            }
            if argument.hasPrefix("--repo=") { return String(argument.dropFirst(7)) }
            if argument.hasPrefix("-R"), argument.count > 2 { return String(argument.dropFirst(2)) }
        }
        return nil
    }

    static func repositoryArguments(_ arguments: [String], context: GitRepositoryContext?) -> [String] {
        let family = arguments.first ?? ""
        let action = arguments.dropFirst().first ?? ""
        let acceptsRepo = family == "pr" || (family == "run" && action == "view")
        guard acceptsRepo,
              repositoryOption(in: arguments) == nil,
              !arguments.contains("--repo"), !arguments.contains("-R"),
              let context, let base = repositorySpecifier(context.baseRemoteURL) else { return arguments }
        var result = arguments
        if family == "pr", result.count > 2, result[1] == "view", !result[2].hasPrefix("-"),
           Int(result[2]) == nil, !result[2].contains(":"),
           let publication = repositorySpecifier(context.publishRemoteURL), publication != base {
            let pieces = publication.split(separator: "/")
            if pieces.count == 3 { result[2] = "\(pieces[1]):\(result[2])" }
        }
        if family == "pr", action == "create", !result.contains("--head"),
           context.publishBranch != "HEAD",
           let publication = repositorySpecifier(context.publishRemoteURL), publication != base {
            let pieces = publication.split(separator: "/")
            if pieces.count == 3 { result += ["--head", "\(pieces[1]):\(context.publishBranch)"] }
        }
        result += ["--repo", base]
        return result
    }

    static func repositorySpecifier(_ remote: String?) -> String? {
        guard let remote, let host = repositoryHost(remote) else { return nil }
        let path: String
        if let url = URL(string: remote), url.host != nil {
            path = url.path
        } else if let colon = remote.firstIndex(of: ":") {
            path = String(remote[remote.index(after: colon)...])
        } else { return nil }
        var pieces = path.split(separator: "/").map(String.init)
        guard pieces.count == 2 else { return nil }
        if pieces[1].hasSuffix(".git") { pieces[1].removeLast(4) }
        guard pieces.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }) else { return nil }
        return "\(host)/\(pieces[0])/\(pieces[1])"
    }

    static func repositoryHost(_ remote: String?) -> String? {
        guard let remote else { return nil }
        if let host = URL(string: remote)?.host { return host.lowercased() }
        if let at = remote.firstIndex(of: "@"), let colon = remote[at...].firstIndex(of: ":") {
            return String(remote[remote.index(after: at)..<colon]).lowercased()
        }
        return nil
    }

    public static func readPullRequest(for workspace: Workspace, maxAge: Duration = .zero) async -> PullRequestRead {
        do { return .current(try await pullRequest(for: workspace, maxAge: maxAge)) } catch { return .unavailable(.classify(error)) }
    }
}
