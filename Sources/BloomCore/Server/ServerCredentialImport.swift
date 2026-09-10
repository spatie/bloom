import Foundation

/// Metadata discovery never exports credentials. The explicit import action reads them privately.
public enum ServerCredentialImport {
    public enum Provider: String, Sendable { case github, codex }

    public enum Candidate: Hashable, Sendable, Identifiable {
        case github(hostname: String, user: String)
        case codex(home: String)

        public var id: String {
            switch self {
            case .github(let hostname, let user): "github:\(hostname):\(user)"
            case .codex(let home): "codex:\(home)"
            }
        }
        public var provider: Provider {
            switch self {
            case .github: .github
            case .codex: .codex
            }
        }
        public var displayName: String {
            switch self {
            case .github(_, let user): user
            case .codex: "Codex"
            }
        }
        public var detail: String {
            switch self {
            case .github(let host, _): host
            case .codex(let home): "Credential cache in \(home). File storage is checked before import."
            }
        }
    }

    public struct Discovery: Sendable {
        public let candidates: [Candidate]
        public let notices: [String]
        public init(candidates: [Candidate], notices: [String]) { self.candidates = candidates; self.notices = notices }
    }

    public struct Outcome: Sendable {
        public let verified: Bool
        public let message: String
        public let removalGuidance: String
        public init(verified: Bool, message: String, removalGuidance: String) {
            self.verified = verified; self.message = message; self.removalGuidance = removalGuidance
        }
    }

    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public let recovery: String
        public init(message: String, recovery: String) { self.message = message; self.recovery = recovery }
        public var errorDescription: String? { message }
        public var recoverySuggestion: String? { recovery }
    }

    public static func discover() async throws -> Discovery {
        var candidates: [Candidate] = []
        var notices: [String] = []
        if let gh = Shell.which("gh") {
            do {
                let environment = try localEnvironment()
                let query = "[.hosts | to_entries[] | .key as $host | .value[] | {hostname:$host,user:.login,state:.state}]"
                let result = try await ServerCredentialImportProcess.run(gh, ["auth", "status", "--json", "hosts", "--jq", query], environment: environment, limit: 32768)
                struct Account: Decodable { let hostname: String; let user: String; let state: String? }
                guard result.status == 0 else { throw failure("GitHub account discovery failed.") }
                let accounts = try JSONDecoder().decode([Account].self, from: result.output)
                if accounts.contains(where: { $0.state != "success" }) { notices.append("Some GitHub accounts need to sign in again and cannot be imported yet.") }
                candidates += accounts.filter { $0.state == "success" && validHost($0.hostname) && validUser($0.user) }.map { .github(hostname: $0.hostname, user: $0.user) }
            } catch is CancellationError { throw CancellationError() } catch {
                notices.append("GitHub accounts could not be listed. Sign in with GitHub CLI on this Mac, or use Sign In on the server.")
            }
        } else { notices.append("GitHub CLI is not installed on this Mac.") }
        let home = codexHome(environment: Shell.environment())
        if let home, ServerCredentialImportFiles.isRegularOwnedFile(home.appendingPathComponent("auth.json")) {
            candidates.append(.codex(home: home.path))
        } else { notices.append("No file-based Codex sign-in was found. Keychain credentials are not exported; use Sign In on the server.") }
        var unique = Set<Candidate>()
        return Discovery(candidates: candidates.filter { unique.insert($0).inserted }, notices: notices)
    }

    public static func importCredential(_ candidate: Candidate, to connection: ServerSetupConnection) async throws -> Outcome {
        try validate(candidate)
        return try await withPreflight({ try await remote(candidate, connection: connection, phase: "check", input: Data()) }) {
            try await importCheckedCredential(candidate, connection: connection)
        }
    }

    static func withPreflight(_ check: @Sendable () async throws -> RemoteReply,
                              operation: @Sendable () async throws -> Outcome) async throws -> Outcome {
        try checkRemote(await check(), phase: "check")
        try Task.checkCancellation()
        return try await operation()
    }

    private static func importCheckedCredential(_ candidate: Candidate, connection: ServerSetupConnection) async throws -> Outcome {
        let payload: Data
        switch candidate {
        case .github(let hostname, let user):
            guard let gh = Shell.which("gh") else { throw failure("GitHub CLI is missing on this Mac.") }
            let result = try await ServerCredentialImportProcess.run(gh, ["auth", "token", "--hostname", hostname, "--user", user], environment: localEnvironment(), limit: 16384)
            guard result.status == 0, let value = String(data: result.output, encoding: .utf8) else { throw failure("The selected GitHub credential could not be read.") }
            let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, token.utf8.count <= 8192, token.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value < 127 }) else {
                throw failure("The selected GitHub credential is not valid.")
            }
            payload = Data((token + "\n").utf8)
        case .codex(let home):
            let folder = URL(fileURLWithPath: home)
            let held = try ServerCredentialImportFiles.Folder(folder)
            try ServerCredentialImportFiles.checkCodexStorage(held)
            payload = try held.read("auth.json", limit: 131072)
            guard ServerCredentialImportFiles.validCodexCache(payload) else { throw failure("The Codex file is not a supported sign-in cache.") }
        }
        try Task.checkCancellation()
        let result = try await remote(candidate, connection: connection, phase: "import", input: payload)
        try checkRemote(result, phase: "import")
        let removal: String
        switch candidate {
        case .github(let host, let user): removal = "On the server: gh auth logout --hostname \(host) --user \(user). Revoke the credential in GitHub settings to invalidate every copy."
        case .codex: removal = "On the server: codex logout. Revoke the sign-in or API key with its provider to invalidate every copy."
        }
        let message = switch result.status {
        case "verified": "The account is available on the server."
        case "cacheAccepted": "Imported. Provider access will be checked when you send a prompt."
        default: "The credential was imported, but its sign-in could not be verified. Check the server before retrying."
        }
        return Outcome(verified: result.status == "verified", message: message, removalGuidance: removal)
    }

    static func localEnvironment(_ source: [String: String] = Shell.environment()) throws -> [String: String] {
        var result = transportEnvironment(source)
        for key in ["GH_CONFIG_DIR", "XDG_CONFIG_HOME"] {
            if let value = source[key] {
                guard value.hasPrefix("/"), !value.contains("\0") else { throw failure("GitHub's configuration directory must use an absolute path.") }
                result[key] = value
            }
        }
        return result
    }

    static func transportEnvironment(_ source: [String: String] = Shell.environment()) -> [String: String] {
        ["PATH": source["PATH"] ?? "/usr/bin:/bin", "HOME": source["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
         "LANG": "C.UTF-8", "GH_PROMPT_DISABLED": "1", "GIT_TERMINAL_PROMPT": "0", "GH_BROWSER": "false"]
    }

    static func codexHome(environment: [String: String]) -> URL? {
        let path = environment["CODEX_HOME"] ?? (environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path) + "/.codex"
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return ServerCredentialImportFiles.canonicalDirectory(URL(fileURLWithPath: path))
    }

    static func validHost(_ host: String) -> Bool { host.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$"#, options: .regularExpression) != nil && !host.contains("..") }
    static func validUser(_ user: String) -> Bool { user.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$"#, options: .regularExpression) != nil }
    private static func validate(_ candidate: Candidate) throws {
        switch candidate {
        case .github(let host, let user): guard validHost(host), validUser(user) else { throw failure("Choose a valid GitHub host and account.") }
        case .codex(let home): guard home.hasPrefix("/"), !home.contains("\0") else { throw failure("The Codex home directory is not valid.") }
        }
    }
    static func failure(_ message: String) -> Failure {
        Failure(message: message, recovery: "Use Sign In on the server, or correct this Mac's selected account and retry. Existing server credentials are never replaced.")
    }
}
