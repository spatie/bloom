import Foundation

/// A subagent's own transcript, read off the file the CLI wrote for it.
///
/// **What `output_file` turned out to be**, because this was the one thing worth checking rather
/// than assuming. `system/task_notification.output_file` is an absolute path to
/// `<cwd slug>/<session>/tasks/<task_id>.output`, which is a **symlink** into
/// `~/.claude/projects/<cwd slug>/<session>/subagents/agent-<task_id>.jsonl`. The target is NDJSON
/// in the same shape as Claude Code's own transcripts: one object per line with a `type`, and for
/// `user` and `assistant` a `message` whose `content` is either a bare string or the usual array
/// of typed blocks. It is written for a subagent that failed exactly as it is for one that
/// worked: the three failed subagents in the capture each left a four line file holding the
/// prompt, two attachment records and an assistant message carrying the API error. So there is no
/// need for the fallback to Bloom's own nested rows, and this is the honest source.
///
/// Bloom does not own the file, which is why nothing here throws on a shape it does not know: a
/// line that will not parse is skipped, a file that will not open is a sentence in the pane, and
/// a format that changes under us degrades to fewer entries rather than to an empty pane.
public struct SubagentTranscript: Sendable, Hashable {
    public struct Entry: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable {
            /// The prompt the parent gave it. Always the first line of the file.
            case prompt
            case text
            case thinking
            case tool
            case toolResult
            /// An assistant message the CLI marked as an API error.
            case failure
        }

        public let id: Int
        public let kind: Kind
        /// The tool's name, for a tool entry. Empty otherwise.
        public let title: String
        public let body: String

        public init(id: Int, kind: Kind, title: String = "", body: String) {
            self.id = id
            self.kind = kind
            self.title = title
            self.body = body
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The last thing the subagent said, which is its answer. Nil when it never said anything.
    public var answer: Entry? {
        entries.last { $0.kind == .text || $0.kind == .failure }
    }

    /// Read one file of NDJSON.
    ///
    /// `attachment` records are skipped whole. In the capture two of every four lines were one,
    /// each carrying the subagent's entire deferred tool list, thousands of characters of it, and
    /// none of it is an account of what the subagent did.
    public static func parse(_ text: String) -> SubagentTranscript {
        var entries: [Entry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let json = JSONValue.parse(String(line)) else { continue }
            entries.append(contentsOf: read(json, from: entries.count))
        }
        return SubagentTranscript(entries: entries)
    }

    private static func read(_ json: JSONValue, from index: Int) -> [Entry] {
        guard let type = json["type"]?.stringValue else { return [] }
        guard type == "user" || type == "assistant" else { return [] }
        guard let message = json["message"] else { return [] }
        let isError = json["isApiErrorMessage"]?.boolValue ?? false

        // The first user line of a subagent's file is the prompt it was handed, and it arrives as
        // a bare string rather than as blocks.
        if let content = message["content"]?.stringValue {
            let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return [] }
            return [Entry(id: index, kind: type == "user" ? .prompt : .text, body: body)]
        }

        var entries: [Entry] = []
        for block in message["content"]?.arrayValue ?? [] {
            guard let entry = read(block: block, id: index + entries.count, isError: isError) else {
                continue
            }
            entries.append(entry)
        }
        return entries
    }

    private static func read(block: JSONValue, id: Int, isError: Bool) -> Entry? {
        switch block["type"]?.stringValue {
        case "text":
            let body = (block["text"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return Entry(id: id, kind: isError ? .failure : .text, body: body)

        case "thinking":
            let body = (block["thinking"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return Entry(id: id, kind: .thinking, body: body)

        case "tool_use":
            // The input verbatim. A subagent's transcript is read to find out what it actually
            // did, and a summarised tool call is the half that gets summarised away.
            return Entry(
                id: id,
                kind: .tool,
                title: block["name"]?.stringValue ?? "",
                body: (block["input"] ?? .null).prettyPrinted
            )

        case "tool_result":
            let body = text(ofResult: block["content"])
            guard !body.isEmpty else { return nil }
            return Entry(id: id, kind: .toolResult, body: body)

        default:
            return nil
        }
    }

    /// A tool result is a string on some lines and an array of text blocks on others, and both
    /// shapes appear in one file.
    private static func text(ofResult content: JSONValue?) -> String {
        guard let content else { return "" }
        if let string = content.stringValue { return string }
        return (content.arrayValue ?? [])
            .compactMap { $0["text"]?.stringValue }
            .joined(separator: "\n")
    }
}
