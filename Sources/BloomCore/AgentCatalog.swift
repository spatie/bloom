import Foundation

// MARK: - Status

/// One label/value row of the account table an agent settings screen renders.
///
/// A value is always derived, never raw file content, because the files these facts come from
/// hold live credentials.
public struct AgentDetail: Sendable, Hashable, Identifiable {
    public var label: String
    public var value: String

    public var id: String { label }

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct AgentStatus: Sendable, Hashable, Identifiable {
    public enum Connection: Sendable, Hashable {
        case notInstalled
        /// Binary found, no account facts available. The honest state for a CLI whose auth file
        /// format Bloom has not verified.
        case installed
        case connected
    }

    public var kind: AgentKind
    public var connection: Connection
    public var executablePath: String?
    public var version: String?
    /// Ordered label/value pairs to render as a table. Never contains a secret.
    public var details: [AgentDetail]
    /// Resolved, symlinks followed, nil when the file or directory is absent.
    public var configPath: String?

    public var id: String { kind.rawValue }

    public init(
        kind: AgentKind,
        connection: Connection,
        executablePath: String? = nil,
        version: String? = nil,
        details: [AgentDetail] = [],
        configPath: String? = nil
    ) {
        self.kind = kind
        self.connection = connection
        self.executablePath = executablePath
        self.version = version
        self.details = details
        self.configPath = configPath
    }
}

// MARK: - Codex claims

/// The subset of the Codex `id_token` claims that are safe to show.
///
/// The signature is deliberately not verified: the CLI is the thing that authenticates, and
/// Bloom only reads the payload so it can print a plan and an email address.
public struct CodexAccount: Sendable, Hashable {
    public var email: String?
    public var name: String?
    public var planType: String?
    public var expiresAt: Date?

    public init(email: String? = nil, name: String? = nil, planType: String? = nil, expiresAt: Date? = nil) {
        self.email = email
        self.name = name
        self.planType = planType
        self.expiresAt = expiresAt
    }

    /// True only when an expiry is present and has passed, so a token without an `exp` claim is
    /// never reported as broken.
    public func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt < now
    }

    public var isEmpty: Bool {
        email == nil && name == nil && planType == nil && expiresAt == nil
    }
}

// MARK: - Catalog

/// Detects the installed agent CLIs and the non-secret facts about the account each one is
/// signed in with.
///
/// An actor because the settings screen calls this on every appearance and a refresh button
/// calls it again: the results are cached until `invalidate()`, so repeated views cost nothing.
public actor AgentCatalog {
    /// Per-agent executable path chosen by the user, overriding PATH lookup.
    private let overrides: [AgentKind: String]
    private var cache: [AgentKind: AgentStatus] = [:]
    /// Detections that have been started and not yet finished, so a second caller joins the one
    /// already running instead of starting its own.
    private var inFlight: [AgentKind: Task<AgentStatus, Never>] = [:]

    /// How many detections have actually been run, as opposed to served from the cache or joined
    /// while already in flight. Exists so the sharing can be asserted on rather than assumed.
    public private(set) var detectionCount = 0

    public init(overrides: [AgentKind: String] = [:]) {
        self.overrides = overrides
    }

    /// Detects everything, concurrently. Cheap enough to call on view appearance.
    public func statuses() async -> [AgentStatus] {
        let resolved = await withTaskGroup(of: (AgentKind, AgentStatus).self) { group in
            for kind in AgentKind.allCases {
                group.addTask { [self] in (kind, await resolvedStatus(for: kind)) }
            }
            var byKind: [AgentKind: AgentStatus] = [:]
            for await (kind, status) in group { byKind[kind] = status }
            return byKind
        }
        return AgentKind.allCases.compactMap { resolved[$0] }
    }

    public func status(for kind: AgentKind) async -> AgentStatus {
        await resolvedStatus(for: kind)
    }

    /// Clears the cache so a Refresh button does real work.
    public func invalidate() {
        cache.removeAll()
        // A detection started before this call describes the world the user just asked to have
        // looked at again, so its answer must not be filed as fresh when it lands.
        inFlight.removeAll()
    }

    /// The cached status, or the detection that will produce it.
    ///
    /// Reading the cache and writing it back used to be separated by an `await`, and that
    /// suspension is where a second caller lands. The settings screen detects on every
    /// appearance and the Refresh button detects again, so both callers ran the whole thing:
    /// three CLI version subprocesses and a handful of config file reads, twice. Sharing the
    /// in-flight task means one detection per agent no matter how many callers arrive.
    private func resolvedStatus(for kind: AgentKind) async -> AgentStatus {
        if let cached = cache[kind] { return cached }

        let task: Task<AgentStatus, Never>
        if let running = inFlight[kind] {
            task = running
        } else {
            let override = overrides[kind]
            task = Task { await Self.detect(kind, override: override) }
            inFlight[kind] = task
            detectionCount += 1
        }

        let status = await task.value

        // Only file the result if this is still the detection the catalog is waiting for. An
        // `invalidate()` during the await means the user asked for a fresh look, and caching an
        // answer gathered before they asked would defeat exactly that.
        if inFlight[kind] == task {
            inFlight[kind] = nil
            cache[kind] = status
        }
        return status
    }

    // MARK: - Detection

    static func detect(_ kind: AgentKind, override: String?) async -> AgentStatus {
        let configPath = resolvedPath(kind.configPath)

        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            let wanted = expandingTilde(override.trimmingCharacters(in: .whitespaces))
            guard let path = Shell.which(wanted) else {
                // Falling back to PATH here would silently run a different binary than the one
                // the user pointed at, so the misconfiguration is reported instead.
                return AgentStatus(
                    kind: kind,
                    connection: .notInstalled,
                    details: [
                        AgentDetail(label: "Custom path", value: wanted),
                        AgentDetail(label: "Problem", value: "No executable file at the configured path"),
                    ],
                    configPath: configPath
                )
            }
            return await describe(kind, executablePath: path, configPath: configPath)
        }

        guard let path = Shell.which(kind.executableName) else {
            return AgentStatus(kind: kind, connection: .notInstalled, configPath: configPath)
        }
        return await describe(kind, executablePath: path, configPath: configPath)
    }

    private static func describe(
        _ kind: AgentKind,
        executablePath: String,
        configPath: String?
    ) async -> AgentStatus {
        let version = await readVersion(executablePath: executablePath)

        let details: [AgentDetail]
        switch kind {
        case .claudeCode:
            let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
            details = claudeDetails(
                accountJSON: readFile(claudeAccountPath),
                version: version,
                apiKeyIsSet: !(key ?? "").isEmpty
            )
        case .codex:
            details = codexDetails(authJSON: readFile(codexAuthPath))
        case .cursor, .openCode:
            // Their auth file formats are not verified, so claiming an account would be a guess.
            details = []
        }

        return AgentStatus(
            kind: kind,
            connection: details.isEmpty ? .installed : .connected,
            executablePath: executablePath,
            version: version,
            details: details,
            configPath: configPath
        )
    }

    static var claudeAccountPath: String { "\(NSHomeDirectory())/.claude.json" }
    static var codexAuthPath: String { "\(NSHomeDirectory())/.codex/auth.json" }

    private static func readFile(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    // MARK: - Version

    static func readVersion(executablePath: String) async -> String? {
        // Short timeout because a hung CLI must not hold up a settings screen.
        guard let result = try? await Shell.run(executablePath, ["--version"], timeout: .seconds(5)) else {
            return nil
        }
        let stdout = result.trimmed
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = stdout.isEmpty ? stderr : stdout
        return parseVersion(raw)
    }

    /// Pulls the bare version out of a `--version` line, and gives up gracefully.
    ///
    /// The observed formats are `2.1.234 (Claude Code)` and `codex-cli 0.147.0`, neither of which
    /// is a contract. When nothing looks like a version the whole first line is shown, which is
    /// still more useful than nothing.
    public static func parseVersion(_ raw: String) -> String? {
        let firstLine = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let firstLine, !firstLine.isEmpty else { return nil }

        for token in firstLine.components(separatedBy: .whitespaces) {
            let candidate = token.hasPrefix("v") ? String(token.dropFirst()) : token
            guard let first = candidate.first, first.isNumber, candidate.contains(".") else { continue }
            let trimmed = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "(),;"))
            if !trimmed.isEmpty { return trimmed }
        }

        return firstLine
    }

    // MARK: - Claude Code

    /// Builds the Claude account table from `~/.claude.json`.
    ///
    /// Pure and injectable so the tests never touch the real file, which holds an OAuth token.
    public static func claudeDetails(
        accountJSON: Data?,
        version: String?,
        apiKeyIsSet: Bool
    ) -> [AgentDetail] {
        let root = accountJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let account = root?["oauthAccount"] as? [String: Any]

        guard account != nil || apiKeyIsSet else { return [] }

        let organizationType = account?["organizationType"] as? String
        let organization = (account?["organizationName"] as? String) ?? unknown
        let email = (account?["emailAddress"] as? String) ?? unknown

        return [
            AgentDetail(label: "Version", value: version ?? unknown),
            AgentDetail(label: "Provider", value: apiKeyIsSet ? "Anthropic API key" : "Anthropic"),
            AgentDetail(
                label: "Login method",
                // A key in the environment wins: the CLI uses it whatever the stored account says.
                value: apiKeyIsSet ? apiKeyLoginMethod : claudeLoginMethod(organizationType)
            ),
            AgentDetail(label: "Organization", value: organization),
            AgentDetail(label: "Email", value: email),
        ]
    }

    /// `ANTHROPIC_API_KEY` is a live credential, so only its presence is ever rendered.
    static let apiKeyLoginMethod = "API key (ANTHROPIC_API_KEY set)"

    static func claudeLoginMethod(_ organizationType: String?) -> String {
        guard let organizationType, !organizationType.isEmpty else { return unknown }
        return "\(titleCased(organizationType)) account"
    }

    // MARK: - Codex

    /// Builds the Codex account table from `~/.codex/auth.json`.
    ///
    /// `now` is injected so the expiry branch is testable without waiting for a token to lapse.
    public static func codexDetails(authJSON: Data?, now: Date = Date()) -> [AgentDetail] {
        let root = authJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        guard let root else { return [] }

        let authMode = root["auth_mode"] as? String
        let apiKeyIsSet = !((root["OPENAI_API_KEY"] as? String) ?? "").isEmpty
        let tokens = root["tokens"] as? [String: Any]
        let account = (tokens?["id_token"] as? String).flatMap(decodeCodexIDToken)

        if account == nil || account?.isEmpty == true {
            guard apiKeyIsSet else { return [] }
            return [
                AgentDetail(label: "Provider", value: "OpenAI"),
                AgentDetail(label: "Auth", value: codexAuthMethod(authMode, apiKeyIsSet: true)),
                // Never the key itself, only that there is one.
                AgentDetail(label: "API key", value: "Set"),
            ]
        }

        guard let account else { return [] }

        var details = [AgentDetail(label: "Provider", value: "OpenAI")]
        if let plan = account.planType, !plan.isEmpty {
            details.append(AgentDetail(label: "Plan", value: titleCased(plan)))
        }
        details.append(AgentDetail(
            label: "Auth",
            value: codexAuthMethod(authMode, apiKeyIsSet: apiKeyIsSet)
        ))
        details.append(AgentDetail(
            label: "Account",
            value: account.email ?? account.name ?? unknown
        ))
        if account.isExpired(at: now) {
            details.append(AgentDetail(
                label: "Session",
                value: "Expired, sign in again with `codex login`"
            ))
        }
        if apiKeyIsSet {
            details.append(AgentDetail(label: "API key", value: "Set"))
        }
        return details
    }

    static func codexAuthMethod(_ authMode: String?, apiKeyIsSet: Bool) -> String {
        switch authMode {
        case "chatgpt": return "ChatGPT login"
        case "apikey": return "API key"
        case let mode? where !mode.isEmpty: return titleCased(mode)
        default: return apiKeyIsSet ? "API key" : unknown
        }
    }

    /// Reads the claims out of a Codex `id_token` without verifying anything.
    ///
    /// Returns nil rather than throwing for every shape of broken token, because a stale or
    /// hand-edited auth file must degrade to "installed", not to an error dialog.
    public static func decodeCodexIDToken(_ token: String) -> CodexAccount? {
        let segments = token.components(separatedBy: ".")
        guard segments.count >= 2 else { return nil }
        guard let payload = base64URLDecode(segments[1]) else { return nil }
        guard let claims = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            return nil
        }

        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let expiry = (claims["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }

        let account = CodexAccount(
            email: nonEmpty(claims["email"] as? String),
            name: nonEmpty(claims["name"] as? String),
            planType: nonEmpty(auth?["chatgpt_plan_type"] as? String),
            expiresAt: expiry
        )
        return account.isEmpty ? nil : account
    }

    /// base64url, which the JWT spec uses: different alphabet, padding stripped.
    public static func base64URLDecode(_ segment: String) -> Data? {
        guard !segment.isEmpty else { return nil }
        var normalized = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: normalized)
    }

    // MARK: - Helpers

    static let unknown = "unknown"

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// `claude_max` reads as `Claude Max`, `chatgpt` as `Chatgpt`.
    static func titleCased(_ value: String) -> String {
        value
            .components(separatedBy: CharacterSet(charactersIn: "_-"))
            .filter { !$0.isEmpty }
            .map(\.capitalizedFirst)
            .joined(separator: " ")
    }

    static func expandingTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return NSHomeDirectory() + String(path.dropFirst(1))
    }

    /// Resolves symlinks so the settings screen reveals the real file. Several of these paths are
    /// symlinks into a dotfiles repo, and revealing the link itself is useless.
    static func resolvedPath(_ path: String) -> String? {
        let expanded = expandingTilde(path)
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
    }
}
