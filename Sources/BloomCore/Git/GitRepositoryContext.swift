import Foundation

/// Fetching the base and publishing the feature branch are different destinations in a fork.
/// Resolve them together so a change to pushRemote cannot leave PR lookup using another repo.
public struct GitRepositoryContext: Sendable, Equatable {
    public let baseBranch: String
    public let baseRemote: String?
    public let publishBranch: String
    public let publishRemote: String?
    public let baseRemoteURL: String?
    public let publishRemoteURL: String?

    public var baseTrackingRef: String? {
        baseRemote.map { "refs/remotes/\($0)/\(baseBranch)" }
    }

    public var publishTrackingRef: String? {
        publishRemote.map { "refs/remotes/\($0)/\(publishBranch)" }
    }

    /// One config snapshot is shared by every decision. Git has already applied includes,
    /// worktree configuration and precedence before producing these records.
    static func resolve(config: [String: String], base: String, branch: String) -> Self {
        let remotes = config.keys.compactMap { key -> String? in
            guard key.hasPrefix("remote."), key.hasSuffix(".url") else { return nil }
            return String(key.dropFirst(7).dropLast(4))
        }.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
        let primary = remotes.contains("origin") ? "origin" : remotes.min()
        let given = base.hasPrefix("refs/remotes/") ? String(base.dropFirst(13)) : base
        let explicitRemote = remotes.first { given.hasPrefix($0 + "/") }
        let baseBranch = explicitRemote.map { String(given.dropFirst($0.count + 1)) } ?? given
        let configuredBase = config["branch.\(baseBranch).remote"]
        let currentRemote = config["branch.\(branch).remote"]
        let merge = config["branch.\(branch).merge"]
        let baseRemote = explicitRemote ?? config["branch.\(branch).bloom-base-remote"]
            ?? configuredBase ?? currentRemote ?? primary
        let explicitPublication = config["branch.\(branch).pushremote"] ?? config["remote.pushdefault"]
        // A review ref names the base repository's synthetic PR ref, not a writable fork
        // branch. Only explicit publication configuration can supply the missing destination.
        let publishRemote = explicitPublication
            ?? ((merge?.hasPrefix("refs/pull/") ?? false) ? nil
                : ((merge == "refs/heads/\(branch)" ? currentRemote : nil) ?? primary))
        return Self(
            baseBranch: baseBranch,
            baseRemote: baseRemote == "." ? nil : baseRemote,
            publishBranch: branch,
            publishRemote: publishRemote == "." ? nil : publishRemote,
            baseRemoteURL: baseRemote.flatMap { config["remote.\($0).url"] },
            publishRemoteURL: publishRemote.flatMap { config["remote.\($0).pushurl"] ?? config["remote.\($0).url"] }
        )
    }
}

extension Git {
    public static func remoteNames(of directory: String) async throws -> [String] {
        try await check(["remote"], in: directory).lines
    }

    static func recordBase(_ context: GitRepositoryContext, for branch: String, in directory: String) async throws {
        try validate(branch: branch)
        try await check(["config", "branch.\(branch).gh-merge-base", context.baseBranch], in: directory)
        if let remote = context.baseRemote {
            try await check(["config", "branch.\(branch).bloom-base-remote", remote], in: directory)
        }
    }

    public static func repositoryContext(
        in directory: String, baseBranch: String? = nil, branch: String? = nil
    ) async throws -> GitRepositoryContext {
        let current: String
        if let branch { current = branch } else if let head = headBranch(in: directory) {
            current = head
        } else { current = try await currentBranch(of: directory) ?? "HEAD" }
        let config = try await repositoryConfiguration(in: directory)
        let base: String
        if let baseBranch { base = baseBranch } else if let recorded = config["branch.\(current).gh-merge-base"] {
            base = recorded
        } else if let merge = config["branch.\(current).merge"], merge.hasPrefix("refs/heads/"),
                  merge != "refs/heads/\(current)" {
            base = String(merge.dropFirst(11))
        } else {
            base = try await defaultBase(config: config, current: current, in: directory)
        }
        try validate(ref: base, label: "base branch")
        if current != "HEAD" { try validate(branch: current) }
        return GitRepositoryContext.resolve(config: config, base: base, branch: current)
    }

    static func repositoryConfiguration(in directory: String) async throws -> [String: String] {
        let output = try await checkRaw(["config", "--null", "--list", "--includes"], in: directory)
        var config: [String: String] = [:]
        for record in nulRecords(output.stdout) {
            guard let separator = record.firstIndex(of: 10) else { continue }
            let key = String(decoding: record[..<separator], as: UTF8.self)
            config[key] = String(decoding: record[record.index(after: separator)...], as: UTF8.self)
        }
        return config
    }

    static func defaultBase(config: [String: String], current: String, in directory: String) async throws -> String {
        let provisional = GitRepositoryContext.resolve(config: config, base: "main", branch: current)
        if let remote = provisional.baseRemote {
            let prefix = "refs/remotes/\(remote)/"
            let head = try await run(["symbolic-ref", prefix + "HEAD"], in: directory)
            if head.ok, head.trimmed.hasPrefix(prefix) { return String(head.trimmed.dropFirst(prefix.count)) }
        }
        let candidates = ["main", "master", "develop"]
        let names = try await check(
            ["for-each-ref", "--format=%(refname:short)"] + candidates.map { "refs/heads/\($0)" }, in: directory
        ).lines
        return candidates.first(where: { names.contains($0) }) ?? (current == "HEAD" ? "main" : current)
    }
    private static func headBranch(in directory: String) -> String? {
        guard let paths = repositoryPaths(in: directory),
              let head = try? String(contentsOfFile: (paths.gitDirectory as NSString).appendingPathComponent("HEAD"), encoding: .utf8)
        else { return nil }
        let prefix = "ref: refs/heads/"
        guard head.hasPrefix(prefix) else { return "HEAD" }
        return String(head.dropFirst(prefix.count)).trimmingCharacters(in: .newlines)
    }

}
