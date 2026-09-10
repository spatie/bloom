import Foundation

/// A historical sandbox verification, not a guarantee for an arbitrary container or shell command.
public struct ServerBrowserReadiness: Codable, Sendable, Equatable {
    public struct Sandbox: Codable, Sendable, Equatable {
        public var namespace: Bool
        public var pidNamespace: Bool
        public var networkNamespace: Bool
        public var seccomp: Bool
        public var verified: Bool { namespace && pidNamespace && networkNamespace && seccomp }
    }

    public var status: ServerDiagnostics.Check.Status
    public var detail: String
    public var agentVersion: String?
    public var chromeVersion: String?
    public var executable: String?
    public var verifiedAt: Date?
    public var sandbox: Sandbox?
    public var hostOnly: Bool

    public static let unavailable = Self(status: .unavailable,
        detail: "Browser testing is optional and has not completed setup. Docker workspaces need their own sandboxed browser dependencies.", hostOnly: true)

    /// Interprets only the bounded public fields from the root-owned installer receipt.
    /// The host adapter checks ownership, executable access and the service account.
    public static func inspect(_ data: Data?, accountID: UInt32,
                               executableAvailable: (String) -> Bool) -> Self {
        guard let data, data.count <= 65_536 else { return .unavailable }
        struct Receipt: Decodable {
            var ready: Bool
            var uid: UInt32
            var hostOnly: Bool
            var agentVersion: String
            var chromeVersion: String
            var executable: String
            var agentBrowser: String
            var chrome: String
            var verifiedAt: Double
            var sandbox: Sandbox
            var debugging: Debugging
            struct Debugging: Decodable { var loopbackOnly: Bool }
        }
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.ready, receipt.uid == accountID, receipt.hostOnly,
              receipt.sandbox.verified, receipt.debugging.loopbackOnly,
              receipt.verifiedAt.isFinite, receipt.verifiedAt > 0,
              [receipt.agentVersion, receipt.chromeVersion].allSatisfy({ $0.range(of: #"^\d+(\.\d+){2,3}$"#, options: .regularExpression) != nil }),
              receipt.executable == "/opt/bloom-browser/bin/agent-browser",
              [receipt.agentBrowser, receipt.chrome].allSatisfy({ $0.hasPrefix("/opt/bloom-browser/releases/") && !$0.split(separator: "/").contains("..") }),
              [receipt.executable, receipt.agentBrowser, receipt.chrome].allSatisfy(executableAvailable) else {
            return Self(status: .attention, detail: "Browser setup could not be verified for this server account. Run browser setup again.", hostOnly: true)
        }
        return Self(status: .ready,
                    detail: "Chrome sandbox and local debugging were verified during setup. Available to host workspaces; Docker workspaces need their own browser dependencies.",
                    agentVersion: receipt.agentVersion, chromeVersion: receipt.chromeVersion,
                    executable: receipt.executable, verifiedAt: Date(timeIntervalSince1970: receipt.verifiedAt),
                    sandbox: receipt.sandbox, hostOnly: true)
    }
}
