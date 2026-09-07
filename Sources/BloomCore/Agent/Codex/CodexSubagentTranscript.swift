import Foundation

/// Reads a child's thread without resuming it or starting a paid turn, using the existing
/// transcript translator and renderer. This result is presentation only and is never stored.
public enum CodexSubagentTranscript {
    public static func read(_ thread: JSONValue, sessionID: SessionID) -> SubagentTranscript {
        var translation = CodexTranslation()
        var lines: [Data] = []
        let threadID = thread["id"]?.stringValue ?? ""
        for turn in thread["turns"]?.arrayValue ?? [] {
            for raw in turn["items"]?.arrayValue ?? [] {
                guard let item = CodexItem.decode(raw) else { continue }
                if case .userMessage(let message) = item {
                    lines.append(CodexRunner.userPayload(message.text))
                    continue
                }
                let event = CodexItemEvent(
                    item: item, threadID: threadID, turnID: turn["id"]?.stringValue ?? "", raw: Data()
                )
                var events = translation.translate(.itemStarted(event))
                if CodexTranslation.status(of: item) != .inProgress {
                    events += translation.translate(.itemCompleted(event))
                }
                lines.append(contentsOf: events.filter(\.isTranscriptRow).map(\.raw))
            }
        }
        return SubagentTranscript.live(streamLines: lines, sessionID: sessionID)
    }
}
