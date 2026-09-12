import Foundation

/// Public facts only. Command output, environment variables and credentials never cross the wire.
public struct ServerDiagnostics: Codable, Sendable, Equatable {
    public struct Check: Codable, Sendable, Equatable, Identifiable {
        public enum Status: String, Codable, Sendable { case ready, attention, unavailable }
        public enum Kind: String, Codable, Sendable { case git, tmux, github, docker, agents, disk, memory, watches }
        public var id: Kind
        public var title: String
        public var status: Status
        public var detail: String

        public init(id: Kind, title: String, status: Status, detail: String) {
            self.id = id; self.title = title; self.status = status; self.detail = detail
        }
    }

    public var checkedAt: Date
    public var hostname: String
    public var operatingSystem: String
    public var account: String
    public var checks: [Check]
    public var browser: ServerBrowserReadiness?
    public var authentication: [AgentAuthenticationStatus]?
    public var storageManagement: Bool?

    public init(checkedAt: Date, hostname: String, operatingSystem: String, account: String, checks: [Check], browser: ServerBrowserReadiness? = nil, authentication: [AgentAuthenticationStatus]? = nil, storageManagement: Bool? = nil) {
        self.checkedAt = checkedAt; self.hostname = hostname; self.operatingSystem = operatingSystem
        self.account = account; self.checks = checks; self.browser = browser; self.authentication = authentication; self.storageManagement = storageManagement
    }

    public static func decode(_ result: JSONValue) throws -> Self {
        guard let payload = result["diagnostics"]?["_0"] else { throw ConnectionFailure("The server did not return its diagnostics.") }
        return try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(payload))
    }

    public var needsAttention: Bool { checks.contains { $0.status == .attention } || browser?.status == .attention }
    public var summary: String { needsAttention ? "Some checks need attention" : "Server checks complete" }
    public var text: String {
        (["\(hostname) (\(operatingSystem)), account \(account)"] + checks.map {
            "\($0.title) [\($0.status.rawValue)]: \($0.detail)"
        } + (browser.map { ["Browser testing [\($0.status.rawValue)]: \($0.detail)"] } ?? [])).joined(separator: "\n")
    }
}
