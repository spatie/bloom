import Foundation

/// Which forge a repository's pull requests are asked of: GitLab only on positive evidence,
/// GitHub otherwise. A GitHub remote anywhere wins, and nobody is asked. `git.forge` in a
/// settings file overrules detection.
public enum ForgeRouting {
    public enum Decision: Sendable, Equatable {
        case forge(Forge)
        /// Neither GitHub nor gitlab.com: GitLab only if glab is signed in to the host.
        case askGlab(host: String)
    }

    public static func decide(declared: Forge?, baseRemoteURL: String?, remoteURLs: [String]) -> Decision {
        if let declared { return .forge(declared) }
        guard let base = GitHub.repositoryHost(baseRemoteURL) else { return .forge(.gitHub) }
        if isGitHub(base) || remoteURLs.compactMap({ GitHub.repositoryHost($0) }).contains(where: isGitHub) {
            return .forge(.gitHub)
        }
        if isGitLabCom(base) { return .forge(.gitLab) }
        return .askGlab(host: base)
    }

    /// Any host naming GitHub, so Enterprise hosts and SSH aliases like `github-work` are never
    /// probed with glab.
    static func isGitHub(_ host: String) -> Bool {
        host.contains("github")
    }

    static func isGitLabCom(_ host: String) -> Bool {
        host == "gitlab.com" || host.hasSuffix(".gitlab.com")
    }

    /// The hosts beside a GitHub remote that could make the repository GitLab's as well. Empty
    /// without a GitHub remote, because then `decide` answers without anybody being asked.
    static func hostsBesideGitHub(_ hosts: [String]) -> Set<String> {
        guard hosts.contains(where: isGitHub) else { return [] }
        return Set(hosts.filter { !isGitHub($0) })
    }
}

/// `ForgeRouting` applied to a directory, remembered until git's config or a settings file changes,
/// or for as long as a glab refusal lasts when that refusal is what made it GitHub.
public enum ForgeResolver {
    private static let resolutions = ForgeResolutions()

    public static func client(for directory: String) async -> any ForgeClient.Type {
        client(of: await forge(for: directory))
    }

    public static func client(of forge: Forge) -> any ForgeClient.Type {
        switch forge {
        case .gitHub: GitHubForge.self
        case .gitLab: GitLab.self
        }
    }

    public static func forge(for directory: String) async -> Forge {
        let paths = Git.repositoryPaths(in: directory)
        let checkout = mainCheckout(paths) ?? directory
        let configPath = paths.map { ($0.commonDirectory as NSString).appendingPathComponent("config") }
        let fingerprint = fingerprint(of: [configPath].compactMap { $0 } + SettingsLoader.candidatePaths(repo: checkout))
        if let known = await resolutions.forge(for: directory, fingerprint: fingerprint) { return known }

        let (forge, lasting) = await resolve(directory: directory, checkout: checkout, configPath: configPath)
        // GitHub because glab said no is kept no longer than that no: a VPN that was down comes back.
        let expiry = lasting ? nil : ContinuousClock.now + GlabSignIn.refusalLifetime
        await resolutions.store(forge, for: directory, fingerprint: fingerprint, expiry: expiry)
        return forge
    }

    private static func resolve(
        directory: String, checkout: String, configPath: String?
    ) async -> (forge: Forge, lasting: Bool) {
        if let declared = SettingsLoader.load(repo: checkout).forge { return (declared, true) }
        // Settled from the config file's text where possible, so a GitHub user pays no process.
        let written = configPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        let hosts = remoteURLs(in: written).compactMap { GitHub.repositoryHost($0) }
        if hosts.contains(where: ForgeRouting.isGitHub) { return (.gitHub, true) }
        if !hosts.contains(where: ForgeRouting.isGitLabCom), GlabSignIn.isInstalled() == false { return (.gitHub, true) }

        let context = try? await Git.repositoryContext(in: directory)
        let remotes = await configuredRemoteURLs(in: directory)
        switch ForgeRouting.decide(declared: nil, baseRemoteURL: context?.baseRemoteURL, remoteURLs: remotes) {
        case .forge(let decided): return (decided, true)
        case .askGlab(let host):
            let signedIn = await GlabSignIn.shared.isSignedIn(to: host)
            return (signedIn ? .gitLab : .gitHub, signedIn)
        }
    }

    /// Whether a repository has remotes on both forges and no `git.forge` settling it. `decide`
    /// would quietly pick GitHub there, which is wrong for a GitLab project mirrored to GitHub,
    /// so the owner is asked instead and the answer goes through `remember`. Never without glab:
    /// GitLab is no answer there, and the settings screen hides the choice for the same reason.
    public static func offersBoth(_ directory: String) async -> Bool {
        guard GlabSignIn.isInstalled() else { return false }
        let checkout = mainCheckout(Git.repositoryPaths(in: directory)) ?? directory
        guard SettingsLoader.load(repo: checkout).forge == nil else { return false }
        let hosts = await configuredRemoteURLs(in: directory).compactMap { GitHub.repositoryHost($0) }
        let others = ForgeRouting.hostsBesideGitHub(hosts)
        if others.contains(where: ForgeRouting.isGitLabCom) { return true }
        for host in others where await GlabSignIn.shared.isSignedIn(to: host) { return true }
        return false
    }

    /// Writes the owner's answer to `.bloom/settings.local.toml` in the project's own checkout,
    /// which `forge(for:)` reads for every workspace. Not the shared file: remotes are this
    /// machine's git config, so a teammate with only the GitHub remote must not inherit it.
    public static func remember(_ forge: Forge, for directory: String) throws {
        let checkout = mainCheckout(Git.repositoryPaths(in: directory)) ?? directory
        let path = (checkout as NSString).appendingPathComponent(".bloom/settings.local.toml")
        var document = SettingsDocument(contentsOf: path)
        SettingsWriter.apply(.forge(forge), to: &document)
        SettingsWriter.prepareFolder(for: path, repo: checkout)
        try document.write(to: path)
    }

    private static func configuredRemoteURLs(in directory: String) async -> [String] {
        let config = (try? await Git.repositoryConfiguration(in: directory)) ?? [:]
        return config.filter { $0.key.hasPrefix("remote.") && $0.key.hasSuffix(".url") }.map(\.value)
    }

    /// The `url = ` values of a git config file, without git. Includes and `insteadOf` are not
    /// followed; anything they hide reaches the full resolution instead.
    static func remoteURLs(in config: String) -> [String] {
        config.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].lowercased() == "url" else { return nil }
            return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }

    /// The project's own checkout, where `settings.local.toml` lives.
    static func mainCheckout(_ paths: GitRepositoryPaths?) -> String? {
        guard let common = paths?.commonDirectory, (common as NSString).lastPathComponent == ".git" else { return nil }
        return (common as NSString).deletingLastPathComponent
    }

    private static func fingerprint(of paths: [String]) -> [Date?] {
        paths.map { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
    }
}

private actor ForgeResolutions {
    private var entries: [String: (fingerprint: [Date?], forge: Forge, expiry: ContinuousClock.Instant?)] = [:]

    func forge(for directory: String, fingerprint: [Date?]) -> Forge? {
        guard let entry = entries[directory], entry.fingerprint == fingerprint,
              entry.expiry.map({ ContinuousClock.now < $0 }) ?? true else { return nil }
        return entry.forge
    }

    func store(_ forge: Forge, for directory: String, fingerprint: [Date?], expiry: ContinuousClock.Instant?) {
        entries[directory] = (fingerprint, forge, expiry)
    }
}

/// Whether glab is signed in to a host. One probe per host at a time; a yes is kept for the
/// launch, a no only for a few minutes, because a VPN that was down comes back.
actor GlabSignIn {
    static let shared = GlabSignIn()
    private static let timeout = Duration.seconds(10)
    static let refusalLifetime = Duration.seconds(300)

    private var answers: [String: (signedIn: Bool, at: ContinuousClock.Instant)] = [:]
    private var probes: [String: Task<Bool, Never>] = [:]

    static func isInstalled() -> Bool {
        GitLab.isInstalled
    }

    func isSignedIn(to host: String) async -> Bool {
        if let known = answers[host], known.signedIn || known.at.duration(to: .now) < Self.refusalLifetime {
            return known.signedIn
        }
        if let running = probes[host] { return await running.value }
        let probe = Task { await Self.probe(host) }
        probes[host] = probe
        let answer = await probe.value
        probes[host] = nil
        answers[host] = (answer, .now)
        return answer
    }

    private static func probe(_ host: String) async -> Bool {
        let arguments = ["auth", "status", "--hostname", host]
        if let override = GitLab.commandOverride {
            return (try? await override(arguments, nil))?.ok ?? false
        }
        guard Shell.which("glab") != nil else { return false }
        return (try? await Shell.run("glab", arguments, timeout: timeout))?.ok ?? false
    }
}
