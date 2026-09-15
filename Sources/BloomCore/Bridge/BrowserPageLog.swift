import Foundation

/// What a page has written to its console since Bloom started listening, capped.
///
/// A value in the core rather than an array on the session, because the three things worth
/// getting right here are rules: what a message from the page is allowed to look like, how many
/// are kept, and what reading them says when the page has been talking for an hour.
public struct BrowserConsoleLog: Sendable, Equatable {
    public enum Level: String, Sendable, Equatable, CaseIterable {
        case log, info, warn, error, debug
    }

    public struct Entry: Sendable, Equatable {
        public var sequence: Int
        public var level: Level
        public var text: String
        /// The address the page was at when it said it, because a log that runs across a
        /// navigation otherwise reads as one page saying everything.
        public var address: String
    }

    public private(set) var entries: [Entry] = []
    /// How many were dropped off the front to keep under `capacity`.
    public private(set) var dropped = 0
    /// Whether the script has been put into this page yet. See `BrowserConsoleScript`.
    public var isListening = false
    private var next = 1

    /// A page in a loop can log thousands of lines a second, and only the recent ones are ever
    /// what a model is asking about.
    public static let capacity = 300
    public static let textLimit = 2_000

    public init() {}

    /// Takes one message the script posted, if it is shaped like one. Anything else is ignored:
    /// the handler is reachable by the page, so the body is whatever the page chose to send.
    public mutating func append(_ body: Any?, address: String) {
        guard let object = body as? [String: Any],
              let rawLevel = object["level"] as? String, let level = Level(rawValue: rawLevel),
              let text = object["text"] as? String else { return }
        entries.append(
            Entry(
                sequence: next, level: level, text: String(text.prefix(Self.textLimit)),
                address: address
            )
        )
        next += 1
        if entries.count > Self.capacity {
            let excess = entries.count - Self.capacity
            entries.removeFirst(excess)
            dropped += excess
        }
    }

    public mutating func clear() {
        entries.removeAll()
        dropped = 0
    }

    /// The log as the model reads it, before it goes into its untrusted envelope.
    ///
    /// `errorsOnly` is for the question asked most, which is "did anything go wrong", and which a
    /// page that logs every render answers only three hundred lines down.
    public func rendered(errorsOnly: Bool = false) -> String {
        let shown = errorsOnly ? entries.filter { $0.level == .error || $0.level == .warn } : entries
        guard !shown.isEmpty else {
            return errorsOnly ? "(no errors or warnings)" : "(the console is empty)"
        }
        var lines: [String] = []
        if dropped > 0 {
            lines.append("(\(dropped) older messages were dropped to keep the last \(Self.capacity))")
        }
        var address = ""
        for entry in shown {
            if entry.address != address {
                address = entry.address
                lines.append("# \(address.isEmpty ? "no address" : address)")
            }
            lines.append("[\(entry.level.rawValue)] \(entry.text)")
        }
        return lines.joined(separator: "\n")
    }
}

/// What `browser_network` answers with: the requests out of the page's Resource Timing buffer.
public struct BrowserNetworkLog: Sendable, Equatable {
    public struct Request: Sendable, Equatable {
        public var type: String
        public var address: String
        /// Zero where WebKit did not report one, which is not the same as a failure.
        public var status: Int
        public var milliseconds: Int
        public var bytes: Int
    }

    public var requests: [Request]
    public var total: Int

    public static let limit = 250
    public static let addressLimit = 500

    /// Reads the `{ rows, total }` the script answers with.
    public static func read(_ value: Any?) -> BrowserNetworkLog? {
        guard let object = value as? [String: Any], let rows = object["rows"] as? [String] else {
            return nil
        }
        var requests: [Request] = []
        var index = 0
        while index + 4 < rows.count {
            defer { index += 5 }
            requests.append(
                Request(
                    type: String(rows[index].filter(\.isLetter).prefix(40)),
                    address: String(rows[index + 1].prefix(addressLimit)),
                    status: Int(rows[index + 2]) ?? 0,
                    milliseconds: Int(rows[index + 3]) ?? 0,
                    bytes: Int(rows[index + 4]) ?? 0
                )
            )
        }
        let total = (object["total"] as? NSNumber)?.intValue ?? requests.count
        return BrowserNetworkLog(requests: requests, total: max(total, requests.count))
    }

    /// The requests as the model reads them. `filter` keeps those whose address contains it.
    public func rendered(filter: String?) -> String {
        let needle = filter?.trimmingCharacters(in: .whitespaces) ?? ""
        let shown = needle.isEmpty
            ? requests
            : requests.filter { $0.address.localizedCaseInsensitiveContains(needle) }
        guard !shown.isEmpty else {
            return needle.isEmpty ? "(no requests recorded)" : "(no request address contains \(needle))"
        }
        var lines = shown.map { request in
            let status = request.status > 0 ? String(request.status) : "-"
            let size = request.bytes > 0 ? " \(request.bytes)B" : ""
            return "\(status) \(request.type) \(request.address) \(request.milliseconds)ms\(size)"
        }
        if total > requests.count {
            lines.insert("(only the last \(requests.count) of \(total) requests are listed)", at: 0)
        }
        return lines.joined(separator: "\n")
    }
}
