import Foundation

/// Setup accepts destinations, not SSH command fragments. SSH configuration remains available
/// for aliases, jump hosts and custom ports, but cannot enable forwarding or reuse a connection
/// whose host key was checked against a different trust store.
public enum ServerSetupSSH {
    @discardableResult
    public static func validateDestination(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 512 else { throw invalid() }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw invalid() }
        if parts.count == 2 {
            guard validName(String(parts[0]), allowingDots: true) else { throw invalid() }
        }
        let host = String(parts[parts.count - 1])
        if host.hasPrefix("[") && host.hasSuffix("]") {
            let address = host.dropFirst().dropLast()
            guard address.contains(":"), address.allSatisfy({ $0.isASCII && ("0123456789abcdefABCDEF:.".contains($0)) }) else { throw invalid() }
        } else {
            guard validName(host, allowingDots: true) else { throw invalid() }
        }
        return value
    }

    /// File paths are passed as one argv element. Percent tokens and environment substitutions
    /// are rejected because OpenSSH expands them itself, even without a shell involved.
    public static func validateIdentityFile(_ value: String) throws -> String? {
        if value.isEmpty { return nil }
        guard value.hasPrefix("/"), !value.contains("%"), !value.contains("${"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw invalid() }
        return value
    }

    /// ssh-keygen preserves hashed host fields and optional comments in lookup output. Compare
    /// the key fields, and let a revoked entry veto a duplicate ordinary entry for the same key.
    public static func trustMatches(lookupOutput: String, candidateLine: String) -> Bool {
        let candidate = candidateLine.split(whereSeparator: \.isWhitespace)
        guard candidate.count >= 3, !candidate[0].hasPrefix("@"), !candidate[0].hasPrefix("#") else { return false }
        var matched = false
        for line in lookupOutput.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let first = fields.first, !first.hasPrefix("#") else { continue }
            let marked = first.hasPrefix("@")
            let offset = marked ? 1 : 0
            guard fields.count >= offset + 3,
                  fields[offset + 1] == candidate[1], fields[offset + 2] == candidate[2] else { continue }
            if first == "@revoked" { return false }
            if !marked { matched = true }
        }
        return matched
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func arguments(destination: String, knownHostsFile: String, identityFile: String? = nil, command: String) throws -> [String] {
        let host = try validateDestination(destination)
        guard let knownHosts = try validateIdentityFile(knownHostsFile) else { throw invalid() }
        var arguments = [
            "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(configurationQuote(knownHosts))", "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "UpdateHostKeys=no", "-o", "ConnectTimeout=10", "-o", "ConnectionAttempts=1",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
            "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes",
            "-o", "PermitLocalCommand=no", "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "PreferredAuthentications=publickey",
        ]
        if let identity = try validateIdentityFile(identityFile ?? "") {
            arguments += ["-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes", "-i", identity]
        }
        arguments += ["--", host, command]
        return arguments
    }

    private static func configurationQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func validName(_ value: String, allowingDots: Bool) -> Bool {
        guard let first = value.first, first != "-", first != ".", !value.isEmpty else { return false }
        return value.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-" || allowingDots && character == ".")
        }
    }

    private static func invalid() -> ServerSetupFailure { ServerSetupFailure(code: .invalidAddress) }
}
