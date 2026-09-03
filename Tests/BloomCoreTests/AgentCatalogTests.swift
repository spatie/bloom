import Testing
import Foundation
@testable import BloomCore

// MARK: - Fixtures

/// base64url, as a JWT actually encodes it: swapped alphabet, no padding.
private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// Builds a syntactically real JWT with a made-up payload. Nothing signs it, and nothing reads
/// the signature, which is exactly what the production code assumes.
private func makeIDToken(claims: [String: Any], signature: String = "not-a-real-signature") -> String {
    let header = base64URL(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
    let payload = base64URL(try! JSONSerialization.data(withJSONObject: claims))
    return "\(header).\(payload).\(base64URL(Data(signature.utf8)))"
}

private func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func claudeAccount() -> [String: Any] { [
    "oauthAccount": [
        "emailAddress": "ada@example.com",
        "displayName": "Ada Lovelace",
        "organizationName": "Example Labs",
        "organizationType": "claude_max",
        "organizationRateLimitTier": "default_claude_max_20x",
        "organizationRole": "admin",
    ],
] }

private func codexClaims() -> [String: Any] { [
    "email": "ada@example.com",
    "name": "Ada Lovelace",
    // Well into the next century, so this fixture never starts failing on its own.
    "exp": 4_102_444_800,
    "https://api.openai.com/auth": [
        "chatgpt_plan_type": "prolite",
        "chatgpt_account_id": "acct-fixture",
    ],
] }

private func codexAuthFile(
    claims: [String: Any]? = nil,
    authMode: String = "chatgpt",
    apiKey: Any = NSNull(),
    accessToken: String = "access-token-fixture",
    refreshToken: String = "refresh-token-fixture"
) -> Data {
    let claims = claims ?? codexClaims()
    return json([
        "auth_mode": authMode,
        "OPENAI_API_KEY": apiKey,
        "last_refresh": "2026-08-18T09:00:00Z",
        "tokens": [
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "id_token": makeIDToken(claims: claims),
            "account_id": "acct-fixture",
        ],
    ])
}

// MARK: - Suite

@Suite("AgentCatalog", .tags(.agentProtocol), .scratchDirectory)
struct AgentCatalogTests {

    // MARK: Agent kinds

    @Test("describes every agent kind")
    func describesKinds() {
        #expect(AgentKind.allCases.map(\.label) == ["Claude Code", "Codex", "Cursor", "OpenCode"])
        #expect(AgentKind.allCases.map(\.executableName) == ["claude", "codex", "cursor-agent", "opencode"])
        // Two backends now, and the two that are not on this list are the ones with no runner.
        #expect(AgentKind.allCases.filter(\.canRunWorkspaces) == [.claudeCode, .codex])
        // The sentence the settings screen prints, derived so it cannot say Claude Code alone
        // again once a second backend exists.
        #expect(AgentKind.runnableSentence == "Claude Code and Codex")
        #expect(AgentKind.claudeCode.loginCommand == "claude /login")
        #expect(AgentKind.codex.loginCommand == "codex login")
        #expect(AgentKind.codex.configPath.hasSuffix("/.codex/config.toml"))
        #expect(AgentKind.claudeCode.configPath.hasSuffix("/.claude/settings.json"))
    }

    // MARK: Claude

    @Test("reads a Claude account into five ordered details")
    func readsClaudeAccount() {
        let details = AgentCatalog.claudeDetails(
            accountJSON: json(claudeAccount()),
            version: "2.1.234",
            apiKeyIsSet: false
        )

        #expect(details.map(\.label) == ["Version", "Provider", "Login method", "Organization", "Email"])
        #expect(details.map(\.value) == [
            "2.1.234", "Anthropic", "Claude Max account", "Example Labs", "ada@example.com",
        ])
    }

    @Test("reports unknown rather than dropping fields the Claude account lacks")
    func fillsMissingClaudeFields() {
        let details = AgentCatalog.claudeDetails(
            accountJSON: json(["oauthAccount": ["emailAddress": "ada@example.com"]]),
            version: nil,
            apiKeyIsSet: false
        )

        #expect(details.count == 5)
        #expect(details[0].value == "unknown")
        #expect(details[2].value == "unknown")
        #expect(details[3].value == "unknown")
        #expect(details[4].value == "ada@example.com")
    }

    @Test("returns no Claude details when oauthAccount is missing")
    func handlesMissingClaudeAccount() {
        let withoutAccount = json(["numStartups": 42, "theme": "dark"])
        #expect(AgentCatalog.claudeDetails(accountJSON: withoutAccount, version: "2.1.234", apiKeyIsSet: false).isEmpty)
        #expect(AgentCatalog.claudeDetails(accountJSON: nil, version: "2.1.234", apiKeyIsSet: false).isEmpty)
        #expect(AgentCatalog.claudeDetails(accountJSON: Data("not json".utf8), version: nil, apiKeyIsSet: false).isEmpty)
    }

    @Test("lets an API key in the environment win over the stored Claude account")
    func apiKeyBeatsOAuthAccount() {
        let details = AgentCatalog.claudeDetails(
            accountJSON: json(claudeAccount()),
            version: "2.1.234",
            apiKeyIsSet: true
        )

        #expect(details.map(\.label) == ["Version", "Provider", "Login method", "Organization", "Email"])
        #expect(details[1].value == "Anthropic API key")
        #expect(details[2].value == "API key (ANTHROPIC_API_KEY set)")
    }

    // MARK: Codex

    @Test("reads Codex claims into ordered details")
    func readsCodexAccount() {
        let details = AgentCatalog.codexDetails(authJSON: codexAuthFile())

        #expect(details.map(\.label) == ["Provider", "Plan", "Auth", "Account"])
        #expect(details.map(\.value) == ["OpenAI", "Prolite", "ChatGPT login", "ada@example.com"])
    }

    @Test("still shows the Codex account when the session has expired")
    func flagsExpiredCodexSession() {
        var claims = codexClaims()
        claims["exp"] = 1_600_000_000

        let details = AgentCatalog.codexDetails(authJSON: codexAuthFile(claims: claims))

        #expect(details.map(\.label) == ["Provider", "Plan", "Auth", "Account", "Session"])
        #expect(details[3].value == "ada@example.com")
        #expect(details.last?.value.contains("Expired") == true)
    }

    @Test("keeps a token without an expiry claim usable")
    func toleratesMissingExpiry() {
        var claims = codexClaims()
        claims.removeValue(forKey: "exp")

        let details = AgentCatalog.codexDetails(authJSON: codexAuthFile(claims: claims))

        #expect(details.map(\.label) == ["Provider", "Plan", "Auth", "Account"])
    }

    @Test("returns nothing for a malformed Codex token instead of throwing")
    func survivesMalformedTokens() {
        #expect(AgentCatalog.decodeCodexIDToken("only-one-segment") == nil)
        #expect(AgentCatalog.decodeCodexIDToken("header.!!!not base64!!!.signature") == nil)
        #expect(AgentCatalog.decodeCodexIDToken("header.\(base64URL(Data("plain text".utf8))).sig") == nil)
        #expect(AgentCatalog.decodeCodexIDToken("header.\(base64URL(json(["sub": "x"]))).sig") == nil)
        #expect(AgentCatalog.decodeCodexIDToken("") == nil)

        for token in ["only-one-segment", "a.###.c", ""] {
            let file = json(["auth_mode": "chatgpt", "tokens": ["id_token": token]])
            #expect(AgentCatalog.codexDetails(authJSON: file).isEmpty)
        }
        #expect(AgentCatalog.codexDetails(authJSON: nil).isEmpty)
        #expect(AgentCatalog.codexDetails(authJSON: Data("{ broken".utf8)).isEmpty)
    }

    @Test("describes Codex in API key mode without a token")
    func readsCodexApiKeyMode() {
        let file = json([
            "auth_mode": "apikey",
            "OPENAI_API_KEY": "sk-proj-FAKEKEYVALUE0123456789",
            "tokens": NSNull(),
        ])

        let details = AgentCatalog.codexDetails(authJSON: file)

        #expect(details.map(\.label) == ["Provider", "Auth", "API key"])
        #expect(details.map(\.value) == ["OpenAI", "API key", "Set"])
    }

    // MARK: Versions

    @Test("parses both observed version formats and falls back on anything else")
    func parsesVersions() {
        #expect(AgentCatalog.parseVersion("2.1.234 (Claude Code)") == "2.1.234")
        #expect(AgentCatalog.parseVersion("codex-cli 0.147.0") == "0.147.0")
        #expect(AgentCatalog.parseVersion("v1.2.3") == "1.2.3")
        #expect(AgentCatalog.parseVersion("  0.9.0\nextra noise\n") == "0.9.0")
        #expect(AgentCatalog.parseVersion("built from source") == "built from source")
        #expect(AgentCatalog.parseVersion("   ") == nil)
        #expect(AgentCatalog.parseVersion("") == nil)
    }

    // MARK: Security

    @Test("never puts a credential into a detail")
    func neverLeaksSecrets() {
        let accessToken = "sk-codex-access-QWERTYUIOPASDFGHJKLZXCVBNM1234567890"
        let refreshToken = "sk-codex-refresh-MNBVCXZLKJHGFDSAPOIUYTREWQ0987654321"
        let openAIKey = "sk-proj-OPENAIKEY-abcdefghijklmnopqrstuvwxyz123456"
        let anthropicToken = "sk-ant-oat01-ZYXWVUTSRQPONMLKJIHGFEDCBA9876543210abcdef"

        var claudeFile = claudeAccount()
        claudeFile["oauthToken"] = anthropicToken
        claudeFile["primaryApiKey"] = anthropicToken

        let idToken = makeIDToken(claims: codexClaims(), signature: "signature-\(refreshToken)")
        let codexFile = json([
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": openAIKey,
            "tokens": [
                "access_token": accessToken,
                "refresh_token": refreshToken,
                "id_token": idToken,
                "account_id": "acct-fixture",
            ],
        ])

        let details = AgentCatalog.claudeDetails(
            accountJSON: json(claudeFile), version: "2.1.234", apiKeyIsSet: true
        ) + AgentCatalog.codexDetails(authJSON: codexFile)

        #expect(details.isEmpty == false)

        // Any run of twelve characters from a credential appearing in a rendered value would mean
        // part of that credential reached the UI.
        let secrets = [accessToken, refreshToken, openAIKey, anthropicToken, idToken]
        for secret in secrets {
            let characters = Array(secret)
            for start in 0...(characters.count - 12) {
                let window = String(characters[start..<(start + 12)])
                for detail in details {
                    #expect(detail.value.contains(window) == false, "leaked \(window) in \(detail.label)")
                    #expect(detail.label.contains(window) == false)
                }
            }
        }
    }

    // MARK: Catalog

    @Test("reports a missing override without falling back to PATH")
    func rejectsBrokenOverride() async {
        let missing = TestScratch.unique("bloom-no-such-agent")
        let catalog = AgentCatalog(overrides: [.claudeCode: missing])

        let status = await catalog.status(for: .claudeCode)

        #expect(status.connection == .notInstalled)
        #expect(status.executablePath == nil)
        #expect(status.version == nil)
        #expect(status.details.contains { $0.value == missing })
        #expect(status.details.contains { $0.label == "Problem" })
    }

    @Test("reads trimmed executable overrides from the shared settings table")
    func readsStoredOverrides() async throws {
        let store = try makeTestStore("agent-executable-overrides")
        try await store.setSetting(
            AgentCatalog.executablePathSettingKey(.codex),
            "  /tmp/tools/codex  "
        )
        try await store.setSetting(
            AgentCatalog.executablePathSettingKey(.claudeCode),
            "   "
        )

        let overrides = await AgentCatalog.executablePathOverrides(in: store)

        #expect(overrides == [.codex: "/tmp/tools/codex"])
        #expect(await AgentCatalog.executablePathOverrides(in: nil).isEmpty)
    }

    @Test("an override is the runner command and an empty value keeps the ordinary name")
    func resolvesRunnerExecutable() {
        #expect(AgentCatalog.executable(for: .codex, override: " /tmp/tools/codex ") == "/tmp/tools/codex")
        #expect(AgentCatalog.executable(for: .codex, override: nil) == "codex")
        #expect(AgentCatalog.executable(for: .claudeCode, override: "   ") == "claude")
    }

    @Test("returns one status per kind, in order, and caches until invalidated")
    func cachesStatuses() async {
        let missing = TestScratch.unique("bloom-no-such-agent")
        let catalog = AgentCatalog(overrides: Dictionary(
            uniqueKeysWithValues: AgentKind.allCases.map { ($0, missing) }
        ))

        let first = await catalog.statuses()
        #expect(first.map(\.kind) == AgentKind.allCases)
        #expect(first.allSatisfy { $0.connection == .notInstalled })
        #expect(first.map(\.id) == AgentKind.allCases.map(\.rawValue))

        let cached = await catalog.statuses()
        #expect(cached == first)

        await catalog.invalidate()
        let refreshed = await catalog.statuses()
        #expect(refreshed == first)
    }

    @Test("resolves a config path through its symlinks and reports absence as nil")
    func resolvesConfigPaths() throws {
        let base = TestScratch.unique("bloom-agentcat")
        let real = base + "/real.json"
        let link = base + "/link.json"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: real))
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let resolved = AgentCatalog.resolvedPath(link)
        #expect(resolved?.hasSuffix("/real.json") == true)
        #expect(AgentCatalog.resolvedPath(base + "/absent.json") == nil)
    }
}

/// Detection against the CLIs actually installed on the developer's machine.
///
/// Everything else in this file is hermetic. This one asserts what docs/AGENTS-INTEGRATION.md recorded
/// from this machine, so it is opt in:
///
///     BLOOM_LOCAL_AGENTS=1 ./Tools/test-core.sh AgentCatalogLocal
private let localAgentsEnabled = ProcessInfo.processInfo.environment["BLOOM_LOCAL_AGENTS"] == "1"

@Suite("AgentCatalogLocal", .enabled(if: localAgentsEnabled), .tags(.subprocess))
struct AgentCatalogLocalTests {
    @Test("finds the CLIs this machine has and none that it does not")
    func detectsLocalAgents() async {
        let statuses = await AgentCatalog().statuses()
        let byKind = Dictionary(uniqueKeysWithValues: statuses.map { ($0.kind, $0) })

        for kind in [AgentKind.claudeCode, .codex] {
            let status = byKind[kind]
            #expect(status?.connection != .notInstalled)
            #expect(status?.executablePath?.isEmpty == false)
            #expect(status?.version?.isEmpty == false)
        }

        #expect(byKind[.cursor]?.connection == .notInstalled)
        #expect(byKind[.openCode]?.connection == .notInstalled)
        #expect(byKind[.cursor]?.version == nil)
        #expect(byKind[.openCode]?.version == nil)
    }
}
