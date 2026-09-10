import Foundation
import BloomClient
import Crypto
import NIOSSH

public struct SSHConfiguration: Codable, Sendable, Equatable {
    public static let defaultExecutable = "/home/bloom/bloom/server/current/bin/bloom-server"
    public static let defaultDataDirectory = "/home/bloom/bloom/data"
    public let host: String
    public let port: Int
    public let username: String
    public let executable: String
    public let dataDirectory: String

    public init(host: String, port: Int = 22, username: String, executable: String = Self.defaultExecutable, dataDirectory: String = Self.defaultDataDirectory) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }), !host.contains("/"),
              (1...65535).contains(port), !username.isEmpty,
              !username.contains(where: { $0.isWhitespace }), !username.contains("@"),
              !executable.isEmpty, dataDirectory.hasPrefix("/"),
              ![host, username, executable, dataDirectory].contains(where: { $0.contains("\0") || $0.contains("\n") || $0.contains("\r") }) else {
            throw ConnectionFailure("Enter a server IP address or hostname, SSH username, and an absolute server data directory.")
        }
        self.host = host; self.port = port; self.username = username
        self.executable = executable; self.dataDirectory = dataDirectory
    }

    public var identity: String {
        var url = URLComponents()
        url.scheme = "ssh"; url.host = host; url.port = port == 22 ? nil : port; url.user = username
        // Two runtimes on one account must not share pending submissions or drafts.
        url.path = dataDirectory
        return url.string ?? ""
    }
    public var hostIdentity: String { "[\(host)]:\(port)" }
    public var command: String { "\(Self.quote(executable)) connect --data-dir \(Self.quote(dataDirectory))" }
    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

public enum SSHIdentity {
    public static func generate() -> Data { Curve25519.Signing.PrivateKey().rawRepresentation }
    public static func publicKey(_ privateKey: Data) throws -> String {
        String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)).publicKey)
    }
    public static func fingerprint(publicKey: String) throws -> String {
        let fields = publicKey.split(separator: " ")
        guard fields.count >= 2, let bytes = Data(base64Encoded: String(fields[1])) else {
            throw ConnectionFailure("Invalid SSH host key.")
        }
        return "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

public struct SSHHostTrustRequired: Error, LocalizedError, Sendable {
    public let fingerprint: String
    public var errorDescription: String? { "Verify this server's SSH fingerprint before connecting: \(fingerprint)" }
}
