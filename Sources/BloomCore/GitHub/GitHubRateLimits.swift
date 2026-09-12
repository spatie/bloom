import Foundation

/// A host-wide pause prevents each workspace from independently spending another failed request.
/// The lease protects a new pause from a success belonging to an older concurrent request.
actor GitHubRateLimits {
    private struct Entry {
        var generation = 0
        var attempts = 0
        var retryAt = Date.distantPast
    }

    private var entries: [String: Entry] = [:]

    func check(host: String, interactive: Bool = false, now: Date = Date()) throws -> Int {
        let entry = entries[host.lowercased()] ?? Entry()
        if !interactive && entry.retryAt > now {
            throw GitHubReadFailure(
                reason: .rateLimited, message: "GitHub refresh is paused until its rate limit resets.",
                retryAt: entry.retryAt
            )
        }
        return entry.generation
    }

    @discardableResult
    func limited(host: String, lease: Int, retryAt: Date?, now: Date = Date()) -> Date {
        let key = host.lowercased()
        var entry = entries[key] ?? Entry()
        if entry.generation <= lease {
            entry.generation += 1
            entry.attempts = min(entry.attempts + 1, 6)
            let fallback = now.addingTimeInterval(min(900, 30 * pow(2, Double(entry.attempts - 1))))
            entry.retryAt = max(entry.retryAt, retryAt.flatMap { $0 > now ? $0 : nil } ?? fallback)
        } else if let retryAt {
            entry.retryAt = max(entry.retryAt, retryAt)
        }
        entries[key] = entry
        return entry.retryAt
    }

    func succeeded(host: String, lease: Int, now: Date = Date()) {
        let key = host.lowercased()
        guard var entry = entries[key], entry.generation == lease, entry.retryAt <= now else { return }
        entry.attempts = 0
        entry.retryAt = .distantPast
        entries[key] = entry
    }
}
