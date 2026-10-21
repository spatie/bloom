import Foundation

/// A GitLab project from a remote: the host and the whole path, since groups nest.
struct GitLabProject: Sendable, Hashable {
    let host: String
    let path: String

    init?(remote: String?) {
        guard let remote, let host = GitHub.repositoryHost(remote) else { return nil }
        let rawPath: String
        if let url = URL(string: remote), url.host != nil {
            rawPath = url.path
        } else if let colon = remote.firstIndex(of: ":") {
            rawPath = String(remote[remote.index(after: colon)...])
        } else { return nil }

        var segments = rawPath.split(separator: "/").map(String.init)
        if let last = segments.last, last.hasSuffix(".git") { segments[segments.count - 1] = String(last.dropLast(4)) }
        guard segments.count >= 2, segments.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }) else { return nil }
        self.host = host
        self.path = segments.joined(separator: "/")
    }

    /// The project as the REST API takes it in a path: `group%2Fsubgroup%2Fapp`.
    var apiID: String {
        path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? path
    }

    /// What `glab -R` is given, so glab never has to guess the project from the remotes.
    var webURL: String { "https://\(host)/\(path)" }
}

/// The remote a GitLab project is reached through: its name for git, its project for glab.
struct GitLabRemote: Sendable, Hashable {
    let name: String
    let project: GitLabProject

    /// The base remote when it is on GitLab, else the GitLab remote beside it, preferring
    /// gitlab.com and the hosts glab is signed in to. A GitLab project mirrored to a GitHub
    /// `origin` is read, checked out, pushed to and merged through that remote, never `origin`.
    static func choose(base: String?, remotes: [String: String], signedInHosts: Set<String>) -> GitLabRemote? {
        let candidates = remotes.compactMap { name, url -> GitLabRemote? in
            guard let project = GitLabProject(remote: url), !ForgeRouting.isGitHub(project.host) else { return nil }
            return GitLabRemote(name: name, project: project)
        }.sorted { ($0.name == "origin" ? "" : $0.name) < ($1.name == "origin" ? "" : $1.name) }
        if let atBase = candidates.first(where: { $0.name == base }) { return atBase }
        let known = candidates.first {
            ForgeRouting.isGitLabCom($0.project.host) || signedInHosts.contains($0.project.host)
        }
        return known ?? candidates.first
    }
}
