import Foundation

/// A subagent's own transcript, read as the rows the window already knows how to draw.
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
/// **Why it hands back `Message` values rather than a shape of its own, which is the whole of
/// this file's design.** The version before this invented an `Entry` with a body of plain text,
/// and the pane drew each one as a `Text`. That is a second renderer for a conversation, and it
/// lost every argument the first one had already won: markdown arrived as literal asterisks, a
/// Bash call arrived as pretty printed JSON with a space before the colon, and a page of tool
/// input sat where the transcript would have drawn one line. A subagent's line and a stored
/// transcript row are the same object, so this reads one into the other and the drawing is the
/// drawing the transcript already does. Nothing here is stored: these messages belong to no
/// `messages` row, and `id` says so by being negative.
///
/// **The prompt is a user turn on both sources and it arrives in two different shapes**, which is
/// the bug that put it on screen twice. In the file it is a `user` line whose `content` is a bare
/// string. On the parent's live stream it is a `user` line whose `content` is an ARRAY holding one
/// `text` block, and the reader here used to look at the block's type without looking at whose
/// message it was, so the brief was read back as something the subagent had said and drawn under
/// "Answered" as well as under "Asked". A `text` block on a `user` line is the brief, on either
/// source, and it is taken out of the rows and handed back as `prompt`.
///
/// Bloom does not own the file, which is why nothing here throws on a shape it does not know: a
/// line that will not parse is skipped, a file that will not open is a sentence in the pane, and
/// a format that changes under us degrades to fewer rows rather than to an empty pane.
public struct SubagentTranscript: Sendable, Equatable {
    /// The conversation, oldest first, as the messages a transcript is built from.
    ///
    /// Deliberately not paired up here: a `tool_result` is its own message with the call's id in
    /// `refID`, exactly as the store hands one back, so the window folds it onto its call with the
    /// same rule it uses for every other transcript and the two cannot drift apart.
    public let messages: [Message]

    /// How many messages were dropped off the front to keep the pane bounded. Drawn as a line
    /// saying so, because a transcript that silently starts in the middle is a lie about what
    /// the subagent did.
    public let droppedRows: Int

    /// The brief the subagent was handed, when the source carried one.
    ///
    /// Read back even though `task_started` already carries it, because the two sources fail at
    /// different moments: a pane opened on a turn that has since been replaced has no
    /// `task_started` left to read, and the file has the brief in it either way.
    public let prompt: String

    /// What a background command printed. Empty for an agent.
    ///
    /// Not NDJSON and not parsed: a `local_bash` task writes plain stdout to
    /// `tasks/<task_id>.output`, and the whole of what it has to say is that text.
    public let printed: String

    public init(
        messages: [Message] = [],
        droppedRows: Int = 0,
        prompt: String = "",
        printed: String = ""
    ) {
        self.messages = messages
        self.droppedRows = droppedRows
        self.prompt = prompt
        self.printed = printed
    }

    public var isEmpty: Bool { messages.isEmpty && printed.isEmpty }

    /// How many rows the pane will draw.
    ///
    /// The LAST of them are kept rather than the first: the answer is at the end, and the brief,
    /// which is the one early row worth having, is drawn above the conversation rather than in it.
    /// Higher than the 120 entries this replaced, because a row is now built only when it is
    /// scrolled to and a tool call's payload is only decoded when it is opened, so the number no
    /// longer stands for a screenful of laid out `Text` views.
    public static let rowLimit = 500

    /// Read one file, or one run of stored stream lines, of NDJSON.
    ///
    /// `attachment` records are skipped whole. In the capture two of every four lines were one,
    /// each carrying the subagent's entire deferred tool list, thousands of characters of it, and
    /// none of it is an account of what the subagent did.
    ///
    /// - Parameter sessionID: the session these lines came off, which is the parent's. It is
    ///   carried because a `Message` has one and for no other reason: nothing drawn from these
    ///   rows reads it.
    public static func parse(_ text: String, sessionID: SessionID) -> SubagentTranscript {
        var messages: [Message] = []
        var prompt = ""
        var used = Set<Int64>()

        for source in text.split(whereSeparator: \.isNewline) {
            let raw = Data(source.utf8)
            guard let json = JSONValue.parse(raw) else { continue }
            for reading in read(json, raw: raw) {
                switch reading {
                case .brief(let brief):
                    // The last one wins. A file holds exactly one; a run of stored stream lines
                    // holds one per subagent and this is only ever handed one subagent's.
                    prompt = brief
                case .row(let kind, let payload, let refID):
                    messages.append(Message(
                        id: identifier(for: payload, avoiding: &used),
                        sessionID: sessionID,
                        seq: messages.count,
                        kind: kind,
                        payload: payload,
                        refID: refID
                    ))
                }
            }
        }

        let dropped = max(0, messages.count - rowLimit)
        return SubagentTranscript(
            messages: Array(messages.suffix(rowLimit)), droppedRows: dropped, prompt: prompt
        )
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
    public static func live(streamLines: [Data], sessionID: SessionID) -> SubagentTranscript {
        parse(streamLines.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n"), sessionID: sessionID)
    }

    /// What a background command printed, as the one block of text it is.
    ///
    /// No parsing, because there is nothing to parse: it is the bytes a program wrote to a
    /// terminal. Trimmed only, so an empty capture is an empty transcript and the pane can say
    /// "nothing yet" rather than draw a blank block.
    public static func command(_ text: String) -> SubagentTranscript {
        SubagentTranscript(printed: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Identity

    /// The id a row that was never stored is drawn under.
    ///
    /// **Negative, and that is not decoration.** The window caches how a tool call is drawn under
    /// the row's id alone (`TranscriptPresentationCache`, whose whole argument is that a stored
    /// payload is written once so a presentation taken from it cannot go stale). A `messages`
    /// rowid is a positive `AUTOINCREMENT`, so a synthetic row numbered from zero would read the
    /// label of whichever real row shared its number, in whichever workspace was open.
    ///
    /// Derived from the payload rather than from the position, because this pane re-reads once a
    /// second and hands over from the live stream to the file the moment the subagent ends. Rows
    /// numbered by position would be renumbered by either of those, which moves a cached
    /// presentation onto the wrong call and closes whatever row the reader had opened.
    ///
    /// FNV-1a rather than `Hasher`, because `Hasher` is seeded per process and this wants the same
    /// answer for the same bytes every time, including across the two sources.
    public static func rowID(for payload: Data) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in payload {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return -Int64(hash & 0x7fff_ffff_ffff_ffff) - 1
    }

    /// The same id, stepped down until it is one nothing else in this transcript is using.
    ///
    /// Two identical payloads would otherwise be two rows with one identity, which a list draws
    /// in whatever order it pleases. Every real line carries a `uuid`, so this only ever fires on
    /// a source that has repeated itself.
    private static func identifier(for payload: Data, avoiding used: inout Set<Int64>) -> Int64 {
        var id = rowID(for: payload)
        while used.contains(id) { id -= 1 }
        used.insert(id)
        return id
    }

    // MARK: - Reading one line

    /// What one content block turned out to be.
    private enum Reading {
        /// The brief, which is drawn above the conversation rather than inside it.
        case brief(String)
        case row(kind: MessageKind, payload: Data, refID: String?)
    }

    private static func read(_ json: JSONValue, raw: Data) -> [Reading] {
        guard let type = json["type"]?.stringValue else { return [] }
        guard type == "user" || type == "assistant" else { return [] }
        guard let message = json["message"] else { return [] }
        let isUser = type == "user"

        // The first user line of a file is the brief, and it arrives as a bare string rather than
        // as blocks. An assistant message shaped the same way is the thing it said.
        if let content = message["content"]?.stringValue {
            let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return [] }
            guard !isUser else { return [.brief(body)] }
            guard let payload = oneBlockLine(json, holding: .object([
                "type": .string("text"), "text": .string(body),
            ])) else { return [] }
            return [.row(kind: .assistantText, payload: payload, refID: nil)]
        }

        let blocks = message["content"]?.arrayValue ?? []
        return blocks.compactMap { block in
            read(block: block, in: json, raw: raw, isOnlyBlock: blocks.count == 1, isUser: isUser)
        }
    }

    private static func read(
        block: JSONValue, in json: JSONValue, raw: Data, isOnlyBlock: Bool, isUser: Bool
    ) -> Reading? {
        // The bytes of the line itself wherever the line holds one block, which is every line in
        // every capture measured. It is the payload every renderer downstream wants: the uuid,
        // the model, the usage and `tool_result_meta` are all outside `content` and all of them
        // are lost by rebuilding the line rather than keeping it.
        func payload() -> Data? {
            isOnlyBlock ? raw : oneBlockLine(json, holding: block)
        }

        switch block["type"]?.stringValue {
        case "text":
            let body = (block["text"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            // A text block on a USER line is the brief, not an answer. See the type's header:
            // reading it as an answer is what drew the prompt under both headings.
            guard !isUser else { return .brief(body) }
            guard let payload = payload() else { return nil }
            return .row(kind: .assistantText, payload: payload, refID: nil)

        case "thinking":
            let thought = (block["thinking"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !isUser, !thought.isEmpty, let payload = payload() else { return nil }
            return .row(kind: .thinking, payload: payload, refID: nil)

        case "tool_use":
            guard !isUser, let payload = payload() else { return nil }
            return .row(kind: .toolUse, payload: payload, refID: block["id"]?.stringValue)

        case "tool_result":
            guard let payload = payload() else { return nil }
            return .row(kind: .toolResult, payload: payload, refID: block["tool_use_id"]?.stringValue)

        default:
            return nil
        }
    }

    /// The same line with one block where its content was, for the message that carried several.
    ///
    /// One line means one row throughout Bloom, and `AgentEvent` reads the first block of a
    /// message and no others, so a message with two blocks in it has to become two lines before
    /// either can be drawn. Every key outside `content` is kept, which is what makes this safe to
    /// do to a line Bloom does not own.
    private static func oneBlockLine(_ json: JSONValue, holding block: JSONValue) -> Data? {
        guard case .object(var top) = json, case .object(var message)? = json["message"] else {
            return nil
        }
        message["content"] = .array([block])
        top["message"] = .object(message)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try? encoder.encode(JSONValue.object(top))
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
    /// `SubagentTranscript.rowLimit` rows anyway. A quarter of a megabyte holds far more
    /// than that many lines of anything the capture contained, so in practice this reads whole
    /// files and exists for the one that is not.
    public static let tailBytes = 256 * 1024

    /// Read and parse one subagent's output.
    ///
    /// `path` is `task_notification.output_file`. For an agent it is a symlink to NDJSON in
    /// Claude Code's transcript shape; for a background command it is plain stdout, which is why
    /// the kind is asked for rather than sniffed. Parsing one as the other is what made a
    /// background command's pane empty.
    public static func read(path: String?, kind: SubagentKind = .agent, sessionID: SessionID)
        -> Result<SubagentTranscript, Failure> {
        guard let path, !path.isEmpty else { return .failure(.noFile) }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.missing) }
        do {
            let text = try tail(of: url)
            return .success(kind.writesTranscript
                ? SubagentTranscript.parse(text, sessionID: sessionID)
                : SubagentTranscript.command(text))
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
