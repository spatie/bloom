import Foundation
import Synchronization

/// The GitLab user glab is signed in as, per host, for `gitlab_username` branch prefixes, the
/// GitHub & GitLab settings and onboarding. Read once per launch, and only when glab is installed.
///
/// Host by host rather than one `glab auth status`: that one asks every configured host in turn
/// and took 43 seconds on a machine with one unreachable instance among four.
public enum GitLabIdentity {
    private struct Identity {
        var usernames: [String: String] = [:]
        var resolved = false
    }

    private static let state = Mutex(Identity())

    /// Host to username, for every host glab is signed in to.
    public static var usernames: [String: String] {
        state.withLock(\.usernames)
    }

    /// The username on the first host of this repository's remotes that glab is signed in to.
    public static func username(forRepo repo: String) -> String? {
        let known = usernames
        guard !known.isEmpty,
              let common = Git.repositoryPaths(in: repo)?.commonDirectory,
              let config = try? String(contentsOfFile: (common as NSString).appendingPathComponent("config"), encoding: .utf8)
        else { return nil }
        return ForgeResolver.remoteURLs(in: config).lazy
            .compactMap { GitHub.repositoryHost($0) }
            .compactMap { known[$0] }
            .first
    }

    /// - Parameter force: read again, after a sign in that may have changed the answer.
    public static func resolve(force: Bool = false) async {
        guard force || !state.withLock(\.resolved) else { return }
        let answers = await signedIn()
        guard !Task.isCancelled else { return }
        state.withLock {
            // A host that did not answer, offline or timed out, keeps what it had.
            let kept = $0.usernames.filter { answers.unanswered.contains($0.key) }
            $0.usernames = answers.usernames.merging(kept) { found, _ in found }
            $0.resolved = true
        }
    }

    /// Every configured host glab is signed in to, asked at once, each given a few seconds.
    static func signedIn() async -> (usernames: [String: String], unanswered: Set<String>) {
        guard GitLab.isInstalled else { return ([:], []) }
        let replies = await withTaskGroup(of: (String, [String: String]?).self) { group in
            for host in configuredHosts() {
                group.addTask {
                    let arguments = ["auth", "status", "--hostname", host]
                    let result: ShellResult? = if let override = GitLab.commandOverride {
                        try? await override(arguments, nil)
                    } else {
                        try? await Shell.run("glab", arguments, timeout: .seconds(5))
                    }
                    return (host, result.map { parse($0.stdout + $0.stderr) })
                }
            }
            return await group.reduce(into: [(String, [String: String]?)]()) { $0.append($1) }
        }
        let usernames = replies.compactMap(\.1).reduce(into: [String: String]()) { $0.merge($1) { first, _ in first } }
        return (usernames, Set(replies.filter { $0.1 == nil }.map(\.0)))
    }

    /// The hosts in glab's config, where glab itself looks for it.
    static func configuredHosts(
        environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()
    ) -> [String] {
        var candidates: [String] = []
        if let directory = environment["GLAB_CONFIG_DIR"] { candidates.append(directory) }
        if let xdg = environment["XDG_CONFIG_HOME"] { candidates.append("\(xdg)/glab-cli") }
        candidates += ["\(home)/Library/Application Support/glab-cli", "\(home)/.config/glab-cli"]
        for directory in candidates {
            if let text = try? String(contentsOfFile: "\(directory)/config.yml", encoding: .utf8) {
                return hosts(inConfig: text)
            }
        }
        return []
    }

    /// The keys of the top level `hosts:` map, read without a YAML parser: one indent deeper than
    /// `hosts:`, ending in a colon.
    static func hosts(inConfig text: String) -> [String] {
        var hosts: [String] = []
        var indent: Int?
        var inHosts = false
        for line in text.components(separatedBy: .newlines) {
            let uncommented = line.range(of: " #").map { String(line[..<$0.lowerBound]) } ?? line
            let trimmed = uncommented.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let content = trimmed.drop { $0 == " " }
            let depth = trimmed.count - content.count
            if content.isEmpty || content.hasPrefix("#") { continue }
            if depth == 0 {
                inHosts = content.hasPrefix("hosts:")
                continue
            }
            guard inHosts else { continue }
            if indent == nil { indent = depth }
            guard depth == indent, content.hasSuffix(":") else { continue }
            hosts.append(String(content.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
        }
        return hosts
    }

    /// `✓ Logged in to <host> as <user> (<config path>)` lines, which glab prints per host.
    static func parse(_ status: String) -> [String: String] {
        var usernames: [String: String] = [:]
        for line in status.components(separatedBy: .newlines) {
            guard let range = line.range(of: "Logged in to ") else { continue }
            let words = line[range.upperBound...].split(separator: " ").map(String.init)
            guard words.count >= 3, words[1] == "as" else { continue }
            usernames[words[0]] = words[2]
        }
        return usernames
    }
}
