import Foundation

/// Keep actionable package names and paths while removing credentials, control sequences and
/// opaque token shapes. Redact before truncation so a cut cannot turn a secret into plain text.
public enum ServerSetupDiagnostics {
    public static let lineLimit = 4_096
    public static let detailLimit = 16_384

    public static func optional(_ text: String?, limit: Int = detailLimit) -> String? {
        guard let text else { return nil }
        let value = sanitise(text, limit: limit)
        return value.isEmpty ? nil : value
    }

    public static func sanitise(_ text: String, limit: Int = detailLimit) -> String {
        // Reject a pathological line as a unit instead of retaining a prefix of unknown secret
        // material. Ordinary streamed installer output is much smaller than this ceiling.
        guard text.utf8.count <= 262_144 else { return "[Oversized setup output omitted]" }
        var value = text
        let rules: [(String, String)] = [
            (#"\u001B\][\s\S]*?(?:\u0007|\u001B\\)"#, ""),
            (#"\u001B\[[0-?]*[ -/]*[@-~]"#, ""),
            (#"(?s)-----BEGIN[^\r\n]*PRIVATE KEY-----.*?(?:-----END[^\r\n]*PRIVATE KEY-----|$)"#, "<redacted private key>"),
            (#"(?i)\b(authorization|proxy-authorization|cookie|set-cookie)\s*[:=]\s*[^\r\n]+"#, "$1: <redacted>"),
            (#"(?i)\b([a-z0-9_-]*(?:token|secret|password|passwd|api[_-]?key|private[_-]?key|credential)[a-z0-9_-]*)["']?\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;]+)"#, "$1=<redacted>"),
            (#"(?i)(--(?:password|passwd|token|secret|api-key|client-secret)\s+)(?:"[^"]*"|'[^']*'|\S+)"#, "$1<redacted>"),
            (#"(?i)([a-z][a-z0-9+.-]*://)[^/\s@]+@"#, "$1<redacted>@"),
            (#"(?i)([a-z][a-z0-9+.-]*://[^\s"'?#]+)[?#][^\s"']*"#, "$1?<redacted>"),
            (#"\b(?:gh[pousr]_|github_pat_|sk-|xox[baprs]-)[A-Za-z0-9_-]+"#, "<redacted>"),
        ]
        for (pattern, replacement) in rules + AppLogExcerpt.credentialPatterns {
            value = value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        value = value.replacingOccurrences(of: AppLogExcerpt.catchAll.pattern, with: AppLogExcerpt.catchAll.template, options: .regularExpression)
        value = String(value.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) })
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let maximum = max(0, limit)
        guard value.utf8.count > maximum else { return value }
        return String(decoding: value.utf8.prefix(maximum), as: UTF8.self) + " [truncated]"
    }
}

struct ServerSetupOutputSanitiser {
    private var privateKey = false
    mutating func line(_ value: String) -> String? {
        if privateKey {
            if value.contains("-----END"), value.contains("PRIVATE KEY-----") { privateKey = false }
            return nil
        }
        if value.contains("-----BEGIN"), value.contains("PRIVATE KEY-----") {
            privateKey = !value.contains("-----END")
            return "<redacted private key>"
        }
        return ServerSetupDiagnostics.optional(value, limit: ServerSetupDiagnostics.lineLimit)
    }
}
