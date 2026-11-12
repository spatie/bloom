import Foundation

/// Rewinding a Claude chat to before one of the owner's messages: the conversation, and if asked
/// the files Claude edited since.
///
/// **Claude Code does both itself; Bloom only has to point at the right message.** Measured against
/// Claude Code 2.1.322 in `-p` stream-json mode, the way `AgentRunner` runs it:
///
/// - `--resume <session> --resume-session-at <uuid> --fork-session` continues the conversation
///   from that message *inclusive*, under a new session id, and leaves the original session as it
///   was. Pointing it at the owner's message itself kept that prompt without its answer, so the
///   point to resume at is the last message *before* it.
/// - `claude -p --resume <session> --rewind-files <uuid>` puts back the files as they were when
///   that message was sent, without a model call, and prints "Files rewound to state at message".
///   It only takes the uuid of a user message, and only works for turns that ran with
///   `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=1`. It restores what Claude's own edit tools
///   changed, not what a shell command did.
///
/// Neither flag is in `--help`. Both are what the Agent SDK passes for `resumeSessionAt` and
/// `rewindFiles`, the same standing as `--permission-prompt-tool stdio`, which `AgentRunner`
/// already depends on.
///
/// **Where the uuid comes from.** Claude Code takes a `uuid` on a stream-json user line and keeps
/// it as that message's id, so Bloom picks one and writes it into the line, and the line is what
/// the user row stores (`AgentRunner.send`, `Store.claimDelivery`). A delivered message uses its
/// delivery id, which is already a UUID, so the queue and the row agree without a new column.
/// Messages sent before this existed have no uuid: their conversation can still be rewound,
/// because the point to resume at is an assistant line, which has always carried one, but their
/// files cannot.
public enum ClaudeRewind {
    /// What a rewind to before `target` does.
    public struct Plan: Equatable, Sendable {
        /// The message to resume at, or nil to start a fresh conversation, when the target was the
        /// first thing said.
        public var resumeAt: String?
        /// The target's own uuid, which is what restores files. Nil for a message sent before
        /// Bloom wrote one.
        public var fileRewindPoint: String?
        /// Rows from this sequence number on are removed from the transcript.
        public var removeFromSeq: Int
        /// What the owner typed, to put back in the composer.
        public var prompt: String
    }

    /// The setting a pending resume point is kept under until the forked conversation starts, so a
    /// relaunch in between still resumes at the right place rather than at the full history.
    public static func settingKey(_ sessionID: SessionID) -> String {
        "claude.rewind.resumeAt.\(sessionID.rawValue)"
    }

    /// Set to make `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING` on: Claude Code keeps a backup of
    /// each file before its tools change it, which is what `--rewind-files` restores from.
    public static let checkpointingVariable = "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"

    /// The uuid a user line was sent with, when it was.
    public static func messageUUID(in payload: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        return (json["uuid"] as? String).flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
    }

    /// The uuid to send a delivered message with: its delivery id when that is a UUID, which every
    /// id Bloom mints is.
    public static func turnUUID(for delivery: DeliveryID?) -> String {
        if let raw = delivery?.rawValue, UUID(uuidString: raw) != nil { return raw }
        return UUID().uuidString.lowercased()
    }

    /// The plan for rewinding to before the user row at `seq`, from the chat's rows in order. Nil
    /// when that row is not one of the owner's messages.
    public static func plan(rewindingTo seq: Int, in messages: [Message]) -> Plan? {
        guard let target = messages.first(where: { $0.seq == seq }), target.kind == .user else { return nil }
        let earlier = messages.filter { $0.seq < seq }
        return Plan(
            resumeAt: earlier.reversed().lazy.compactMap(resumePoint(of:)).first,
            fileRewindPoint: messageUUID(in: target.payload),
            removeFromSeq: seq,
            prompt: text(of: target.payload)
        )
    }

    /// A row's uuid when it is a line of the main conversation Claude keeps: an assistant message
    /// or a user line (a prompt or a tool result). A subagent's lines live in a file of their own,
    /// so one with a parent tool call is not a point the main session can resume at.
    static func resumePoint(of message: Message) -> String? {
        switch message.kind {
        case .user, .assistantText, .thinking, .toolUse, .toolResult: break
        default: return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: message.payload) as? [String: Any],
              let type = json["type"] as? String, type == "assistant" || type == "user",
              json["parent_tool_use_id"] == nil || json["parent_tool_use_id"] is NSNull,
              let uuid = json["uuid"] as? String, UUID(uuidString: uuid) != nil else { return nil }
        return uuid
    }

    /// The words of a stored user line, its text blocks joined.
    static func text(of payload: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let message = json["message"] as? [String: Any] else { return "" }
        if let content = message["content"] as? String { return content }
        let blocks = message["content"] as? [[String: Any]] ?? []
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
    }

    /// The arguments for the one-off call that restores files.
    public static func fileRewindArguments(session agentSessionID: String, to uuid: String) -> [String] {
        ["-p", "--resume", agentSessionID, "--rewind-files", uuid]
    }

    /// What `--rewind-files` prints when it worked. Anything else is its error.
    public static func fileRewindSucceeded(_ output: String) -> Bool {
        output.contains("Files rewound to state at message")
    }
}
