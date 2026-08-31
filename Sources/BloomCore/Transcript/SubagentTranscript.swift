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
            /// Bytes a background command printed. Not NDJSON and not parsed: a `local_bash`
            /// task writes plain stdout to `tasks/<task_id>.output`, and the whole of what it
            /// has to say is that text.
            case printed
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
            // Cut here rather than in the pane, so no reader of this type can be handed a
            // megabyte. The HEAD is kept, unlike the transcript's own cut above: a tool result
            // says what it found in its first lines and a file dumped into one is the tail.
            self.body = body.count > SubagentTranscript.bodyLimit
                ? String(body.prefix(SubagentTranscript.bodyLimit)) + "..."
                : body
        }
    }

    public let entries: [Entry]
    /// How many entries were dropped off the front to keep the pane bounded. Drawn as a line
    /// saying so, because a transcript that silently starts in the middle is a lie about what
    /// the subagent did.
    public let droppedEntries: Int

    public init(entries: [Entry] = [], droppedEntries: Int = 0) {
        self.entries = entries
        self.droppedEntries = droppedEntries
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// How many entries the pane will render.
    ///
    /// A fan-out agent that read forty files leaves eighty entries and a long one leaves many
    /// more, and every one of them is a `Text` in a `ScrollView` that is laid out whether or not
    /// it is on screen. The LAST of them are kept rather than the first: the answer is at the end,
    /// and the prompt, which is the one early entry worth having, is drawn from
    /// `task_started.prompt` above rather than from this file.
    public static let entryLimit = 120

    /// How much of one entry is rendered. A tool result can be a whole file.
    public static let bodyLimit = 4_000

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
        let dropped = max(0, entries.count - entryLimit)
        return SubagentTranscript(entries: Array(entries.suffix(entryLimit)), droppedEntries: dropped)
    }

    /// The same reading, taken off Bloom's own stored rows rather than off the CLI's file.
    ///
    /// **Why there is a second source at all.** `output_file` is named on `task_notification`,
    /// which is the line that ENDS a subagent, so for the whole of the run there is no path to
    /// read and the pane had nothing to say. Bloom is not blind for that period: every line the
    /// subagent produces arrives on the parent's own stream carrying `parent_tool_use_id`, and
    /// those rows are already stored, already drawn nested behind a hairline in the transcript,
    /// and already keyed by the `tool_use_id` the subagent carries.
    ///
    /// It is `parse` and not a parser of its own, because a stream-json `assistant` or `user`
    /// line and a line of Claude Code's transcript file are the same object: a `type` and a
    /// `message` whose `content` is a string or the usual array of blocks. The extra keys a
    /// stream line carries (`parent_tool_use_id`, `session_id`) are ignored by the reader, as
    /// every key it does not know is.
    ///
    /// The file stays the honest source once there is one: it is what the CLI wrote for this
    /// task, and this is what Bloom happened to see while it was being written.
    ///
    /// - Parameter streamLines: the stored payloads of the nested rows, in the order they arrived.
    public static func live(streamLines: [Data]) -> SubagentTranscript {
        parse(streamLines.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n"))
    }

    /// What a background command printed, as the one entry it is.
    ///
    /// No parsing, because there is nothing to parse: it is the bytes a program wrote to a
    /// terminal. Trimmed only, so an empty capture is an empty transcript and the pane can say
    /// "nothing yet" rather than draw a blank block.
    public static func printed(_ text: String) -> SubagentTranscript {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return SubagentTranscript() }
        return SubagentTranscript(entries: [Entry(id: 0, kind: .printed, body: body)])
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

/// Reading a subagent's transcript off disk.
///
/// A file Bloom does not own, in a directory Bloom does not own, written by another process that
/// may still be writing it. So every failure is a sentence rather than a throw: the pane's job is
/// to say what it can see, and "the CLI has not written this yet" is a thing it can see.
public enum SubagentOutput: Sendable {
    public enum Failure: Error, Sendable, Hashable {
        /// The notification never named a file.
        case noFile
        /// It named one that is not there. The CLI writes the path into the notification and the
        /// file a moment later, so this is briefly true for a subagent that has just ended.
        case missing
        /// It is there and could not be read: permissions, or a symlink whose target has gone.
        case unreadable(String)
    }

    /// How much of the end of the file is read.
    ///
    /// The pane re-reads once a second while the subagent works (`SubagentPane.refreshSeconds`),
    /// and that is only affordable against a bound. It is the END that is read, because that is
    /// where the answer is and because the pane only renders the last
    /// `SubagentTranscript.entryLimit` entries anyway. A quarter of a megabyte holds far more
    /// than that many lines of anything the capture contained, so in practice this reads whole
    /// files and exists for the one that is not.
    public static let tailBytes = 256 * 1024

    /// Read and parse one subagent's output.
    ///
    /// `path` is `task_notification.output_file`. For an agent it is a symlink to NDJSON in
    /// Claude Code's transcript shape; for a background command it is plain stdout, which is why
    /// the kind is asked for rather than sniffed. Parsing one as the other is what made a
    /// background command's pane empty.
    public static func read(path: String?, kind: SubagentKind = .agent)
        -> Result<SubagentTranscript, Failure> {
        guard let path, !path.isEmpty else { return .failure(.noFile) }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.missing) }
        do {
            let text = try tail(of: url)
            return .success(kind.writesTranscript
                ? SubagentTranscript.parse(text)
                : SubagentTranscript.printed(text))
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
    }

    /// The last `tailBytes` of a file, starting at a line boundary.
    ///
    /// The first partial line is dropped rather than handed on: half a JSON object would be a
    /// skipped line in the NDJSON case and half a word of output in the other, and the second of
    /// those is the one somebody would have believed. A file smaller than the bound is returned
    /// whole, first line and all.
    static func tail(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        guard size > tailBytes else {
            try handle.seek(toOffset: 0)
            let data = try handle.readToEnd() ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        try handle.seek(toOffset: UInt64(size - tailBytes))
        let data = try handle.readToEnd() ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        guard let newline = text.firstIndex(where: \.isNewline) else { return text }
        return String(text[text.index(after: newline)...])
    }
}

extension SubagentOutput.Failure {
    /// What the pane says instead of a transcript.
    ///
    /// Worded per kind, because "this subagent's output" said of a `git push` running in the
    /// background is the same category error that put the two in one list. The empty
    /// `output_file` is the ordinary case for a background command rather than a fault, so
    /// `.noFile` says so plainly instead of blaming the agent for not telling us.
    public func sentence(_ kind: SubagentKind = .agent) -> String {
        switch (self, kind) {
        case (.noFile, .agent):
            "The agent did not say where this subagent's output was written."
        case (.noFile, .command):
            "The agent did not capture this command's output, so there is nothing to show."
        case (.missing, .agent):
            "The agent has not written this subagent's output yet."
        case (.missing, .command):
            "This command has not printed anything yet."
        case (.unreadable(let reason), _):
            "This \(kind.noun)'s output could not be read. \(reason)"
        }
    }
}
