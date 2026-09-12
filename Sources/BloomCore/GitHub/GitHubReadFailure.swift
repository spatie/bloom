import Foundation

/// A missing pull request is an answer. A rate limit or a broken response must never be cached
/// as that answer, especially when a merged branch has left only its PR number behind.
public struct GitHubReadFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Reason: Sendable, Equatable {
        case rateLimited, authentication, unavailable
    }

    public let reason: Reason
    public let message: String
    public let retryAt: Date?

    public init(reason: Reason, message: String, retryAt: Date? = nil) {
        self.reason = reason
        self.message = message
        self.retryAt = retryAt
    }

    public var description: String { message }

    public static func classify(_ error: Error) -> GitHubReadFailure {
        if let failure = error as? GitHubReadFailure { return failure }
        let message = String(describing: error)
        let lower = message.lowercased()
        let authentication = lower.contains("http 401") || lower.contains("authentication failed")
            || lower.contains("bad credentials") || lower.contains("gh auth login")
        return GitHubReadFailure(
            reason: authentication ? .authentication : .unavailable,
            message: authentication ? "Connect GitHub again to refresh pull requests." : String(message.prefix(1_000))
        )
    }

    static func isRateLimit(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("rate limit") || text.contains("rate_limit")
            || text.contains("http 429") || text.contains("too many requests")
    }

    static func retryDate(from output: String, now: Date) -> Date? {
        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { continue }
            let header = fields[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = fields[1].trimmingCharacters(in: .whitespaces)
            if header == "retry-after" {
                if let seconds = TimeInterval(value), seconds >= 0, seconds.isFinite {
                    return now.addingTimeInterval(seconds)
                }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                if let date = formatter.date(from: value), date > now { return date }
            }
            if header == "x-ratelimit-reset", let seconds = TimeInterval(value), seconds.isFinite {
                let date = Date(timeIntervalSince1970: seconds)
                if date > now { return date }
            }
        }
        return nil
    }
}

public enum PullRequestRead: Sendable {
    case current(PullRequest?)
    case unavailable(GitHubReadFailure)
}
