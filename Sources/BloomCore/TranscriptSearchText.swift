import Foundation

/// What of a transcript row goes into the search index.
///
/// Bloom stores a message as the raw JSON line the agent CLI emitted, and there are four of those
/// CLIs with four shapes. Pulling the prose out by naming a path (`message.content[].text` for
/// Claude Code, `msg.text` for Codex) meant one extractor per agent, each of them wrong the first
/// time an agent changed a key, and each of them silently indexing nothing rather than failing.
///
/// So the walk is generic: every string leaf in the document, minus the keys that are known to be
/// machinery rather than words. That is why a Codex transcript is searchable without this file
/// knowing Codex exists, and why a key added by any of the four is picked up rather than dropped.
///
/// The noise list is what stops the index filling with identifiers. A tool_use id or a uuid is a
/// thirty character token nobody will ever type, and a hundred thousand of them make every term
/// in the vocabulary rarer, which is bm25's whole input. Skipping them shrank the index over the
/// owner's real database by a third and made the ranking mean something.
public enum TranscriptSearchText {
    /// How much of one row is indexed.
    ///
    /// A tool result can be a whole file, and a `cat` of a lock file is a megabyte of tokens that
    /// nobody searches for and that drags the index around with it. Eight thousand characters is
    /// past the length of any prose turn in the owner's database (the longest assistant answer
    /// measured under three thousand) while cutting the long tail off the tool output.
    public static let limit = 8_000

    /// Keys whose values are machinery. Both spellings of each, because the CLIs disagree about
    /// snake case and Bloom is not going to arbitrate.
    private static let noiseKeys: Set<String> = [
        "id", "uuid", "type", "subtype", "role", "signature", "model", "version",
        "session_id", "sessionId", "tool_use_id", "toolUseId", "toolUseID",
        "parent_tool_use_id", "parentToolUseId", "call_id", "callId", "request_id", "requestId",
        "media_type", "mediaType", "data", "encoding", "permission_mode", "permissionMode",
        "leaf_uuid", "leafUuid", "message_id", "messageId", "parent_uuid", "parentUuid",
    ]

    /// The kinds worth indexing, and why the rest are not.
    ///
    /// Prose, thinking, tool calls and tool output all go in. Tool calls are in deliberately: the
    /// question this feature exists to answer ("which workspace was it where the agent worked out
    /// the WAL thing") is as often answered by the grep it ran or the file it edited as by a
    /// sentence it wrote, and a search that found the explanation but not the change would send
    /// the reader to the right workspace only half the time.
    ///
    /// `result`, `system` and `notice` rows are token counts, costs and lifecycle chatter with no
    /// words in them. `permissionAsk` is a second copy of a tool call that is already indexed from
    /// its own row, and indexing it again would put the same workspace in the list twice.
    public static func isIndexed(_ kind: MessageKind) -> Bool {
        switch kind {
        case .user, .assistantText, .thinking, .toolUse, .toolResult, .error: true
        case .result, .system, .notice, .permissionAsk: false
        }
    }

    /// The text of one row, or nil when there is nothing in it worth a row in the index.
    public static func indexable(kind: MessageKind, payload: Data) -> String? {
        guard isIndexed(kind) else { return nil }
        // A payload that is not JSON at all is plain text from an older schema, and there is no
        // reason to drop it on the floor.
        guard let json = JSONValue.parse(payload) else {
            return clean(String(decoding: payload, as: UTF8.self))
        }

        var pieces: [String] = []
        var seen: Set<String> = []
        collect(json, key: nil, into: &pieces, seen: &seen)
        return clean(pieces.joined(separator: " "))
    }

    private static func collect(
        _ value: JSONValue,
        key: String?,
        into pieces: inout [String],
        seen: inout Set<String>
    ) {
        // Bail once there is more than the cap's worth: the join below trims to it anyway, and a
        // megabyte tool result should not be walked in full to throw most of it away.
        guard pieces.reduce(0, { $0 + $1.count }) < limit else { return }

        switch value {
        case .string(let text):
            guard let key, !noiseKeys.contains(key) else { return }
            // A string with no letter in it is a hash, a path fragment or a number. The words are
            // what a person types.
            guard text.contains(where: \.isLetter) else { return }
            // The same sentence often appears twice in one line, once in the block and once in the
            // raw message it was lifted from. Indexing it twice would count it twice in bm25.
            guard seen.insert(text).inserted else { return }
            pieces.append(text)
        case .array(let items):
            for item in items { collect(item, key: key, into: &pieces, seen: &seen) }
        case .object(let object):
            // Sorted so the same document always produces the same text, which is what makes a
            // test of this function possible at all.
            for name in object.keys.sorted() {
                guard let child = object[name] else { continue }
                collect(child, key: name, into: &pieces, seen: &seen)
            }
        case .integer, .number, .bool, .null:
            return
        }
    }

    private static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains(where: \.isLetter) else { return nil }
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit))
    }
}
