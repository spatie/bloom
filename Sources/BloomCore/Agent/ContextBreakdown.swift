import Foundation
import Synchronization

/// What fills a Claude Code session's context window, as its `/context` command counts it.
///
/// Asked over a `control_request` of subtype `get_context_usage` on the session's own stdin,
/// because the answer depends on that process: its project, its MCP servers, its transcript.
/// Measured against 2.1.308: it answers without starting a turn or spending anything.
public struct ContextBreakdown: Sendable, Equatable {
    public struct Category: Sendable, Equatable {
        public var name: String
        public var tokens: Int
    }

    /// What is in the window, in the CLI's order. Deferred tools, the autocompact buffer and
    /// the free space are left out: none of them is in front of the model.
    public var categories: [Category]

    public static func request(id: String) -> String {
        ClaudeCodeQuotaSource.encode(.object([
            "type": .string("control_request"),
            "request_id": .string(id),
            "request": .object(["subtype": .string("get_context_usage")]),
        ]))
    }

    public static func decode(_ payload: JSONValue) -> Self? {
        guard let categories = payload["categories"]?.arrayValue else { return nil }
        return Self(categories: categories.compactMap { category in
            guard category["kind"]?.stringValue == "used",
                  let name = category["name"]?.stringValue,
                  let tokens = category["tokens"]?.intValue, tokens > 0 else { return nil }
            return Category(name: name, tokens: tokens)
        })
    }
}

/// Context asks written to a running process, waiting for the line that answers them.
final class ContextBreakdownAsks: Sendable {
    private let waiting = Mutex<[String: CheckedContinuation<ContextBreakdown?, Never>]>([:])

    func add(_ id: String, _ continuation: CheckedContinuation<ContextBreakdown?, Never>) {
        waiting.withLock { $0[id] = continuation }
    }

    /// Whether `raw` was the answer to one of these asks, which is then resolved.
    func answer(_ raw: Data) -> Bool {
        guard let json = JSONValue.parse(raw), json["type"]?.stringValue == "control_response",
              let response = json["response"], let id = response["request_id"]?.stringValue,
              let continuation = waiting.withLock({ $0.removeValue(forKey: id) }) else { return false }
        let payload = response["subtype"]?.stringValue == "success" ? response["response"] : nil
        continuation.resume(returning: payload.flatMap(ContextBreakdown.decode))
        return true
    }

    func giveUp(_ id: String) {
        waiting.withLock { $0.removeValue(forKey: id) }?.resume(returning: nil)
    }

    func giveUpAll() {
        waiting.withLock { waiting in
            defer { waiting = [:] }
            return Array(waiting.values)
        }.forEach { $0.resume(returning: nil) }
    }
}
